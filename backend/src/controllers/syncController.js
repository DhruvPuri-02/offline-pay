// Phase 6: offline synchronization.
//
// Devices do TWO things here:
//
//   POST /api/sync/push  - upload their PENDING_SYNC queue. The server is
//                          the ledger authority: it verifies signatures,
//                          stores each transaction ONCE (idempotent by
//                          transactionId), refuses replays (nonce reuse),
//                          and reports a per-transaction outcome the device
//                          applies to its local SQLite ledger.
//
//   POST /api/sync/pull  - download everything the server knows about the
//                          calling user: payments uploaded by the OTHER
//                          device while this one was offline, plus status
//                          changes (CONFIRMED / REJECTED).
//
// What this phase does NOT do (honest scope, see docs/OFFLINE_FIRST.md):
// there is no authentication (anyone can claim any userId - trust-on-first-
// use key binding only), and there is NO balance arbitration yet: a batch
// can push a sender negative. Server-side double-spend arbitration is
// Phase 7. Balances of EXISTING server users are still moved on confirm,
// so Phase 7 has a ledger to arbitrate against.

import Transaction from '../models/Transaction.js';
import User from '../models/User.js';
import { canonicalPayload, verifyReceiptSignature } from '../utils/transactionSignature.js';

// Sanity cap: a phone's offline queue is small; a huge batch smells wrong.
const MAX_BATCH = 200;

// Every field the canonical payload (and the ledger) depends on.
const REQUIRED_FIELDS = [
  'transactionId',
  'senderId',
  'receiverId',
  'senderWalletId',
  'receiverWalletId',
  'amount',
  'type',
  'timestamp',
];

/** Project a mongoose document (or plain object) to the wire shape the
 *  app's Transaction.fromJson understands. */
const toWire = (t) => ({
  transactionId: t.transactionId,
  senderId: t.senderId,
  receiverId: t.receiverId,
  senderWalletId: t.senderWalletId,
  receiverWalletId: t.receiverWalletId,
  amount: t.amount,
  type: t.type,
  status: t.status,
  description: t.description ?? null,
  nonce: t.nonce ?? null,
  senderPublicKey: t.senderPublicKey ?? null,
  signature: t.signature ?? null,
  rejectionReason: t.rejectionReason ?? null,
  timestamp: t.timestamp instanceof Date ? t.timestamp.toISOString() : t.timestamp,
});

/**
 * Bind the pushing device's public key to its user - trust on first use.
 *
 * This is what completes Phase 5's trust story: after a key is bound,
 * receipts signed by ANY OTHER key cannot be pushed as that sender
 * ("public key mismatch" below). It is still TOFU: there is no login, so
 * the FIRST claim on a userId wins. That weakness is documented, not
 * hidden. A bound key is NEVER overwritten here - rotation needs an
 * authenticated flow this prototype deliberately does not have.
 */
async function registerKey(userId, publicKey) {
  if (!userId || !publicKey) return 'not-provided';

  const user = await User.findOne({ userId });
  if (!user) return 'user-not-found'; // server users are Phase 7 onboarding
  if (!user.publicKey) {
    user.publicKey = publicKey;
    await user.save();
    return 'bound';
  }
  return user.publicKey === publicKey ? 'already-bound' : 'mismatch-ignored';
}

/**
 * Verdict for ONE uploaded transaction.
 *
 * Order matters: verify the signature BEFORE trusting any field, and check
 * replay/idempotency before writing - the database unique indexes are the
 * race-safe backstop for the checks that have windows here.
 */
async function adjudicate(tx, usersById) {
  const id = tx?.transactionId ?? null;
  const rejected = (reason) => ({
    transactionId: id,
    outcome: 'REJECTED',
    serverStatus: 'REJECTED',
    reason,
  });

  // 1. Shape. Malformed input is refused wholesale, not guessed at.
  const missing = REQUIRED_FIELDS.filter(
    (field) => tx?.[field] === undefined || tx?.[field] === null,
  );
  if (missing.length > 0) return rejected(`malformed: missing ${missing.join(', ')}`);
  if (!(Number(tx.amount) > 0)) return rejected('malformed: amount must be > 0');

  // 2. Signature (Phase 5, enforced server-side now). Offline payments are
  //    always signed by the payer; unsigned ones come only from broken or
  //    hostile clients. A signature that exists but does not match the
  //    uploaded fields means the receipt was tampered with in transit.
  if (tx.type === 'OFFLINE_PAYMENT') {
    if (!tx.signature || !tx.senderPublicKey) return rejected('unsigned offline payment');
  }
  if ((tx.signature || tx.senderPublicKey) && !verifyReceiptSignature(tx)) {
    return rejected('invalid signature: the transaction does not match what the payer signed');
  }

  // 3. Key binding: if the SENDER has a registered key, this transaction
  //    must be signed by THAT key - not merely by some self-consistent one.
  const sender = usersById.get(tx.senderId);
  if (sender?.publicKey && tx.senderPublicKey && sender.publicKey !== tx.senderPublicKey) {
    return rejected(
      'public key mismatch: signed with a key that is not registered for this sender',
    );
  }

  // 4. Replay protection: a nonce may only ever belong to ONE transaction.
  //    (Same nonce + same transactionId is handled as a duplicate below.)
  if (typeof tx.nonce === 'string') {
    const reused = await Transaction.findOne({
      nonce: tx.nonce,
      transactionId: { $ne: id },
    });
    if (reused) return rejected('nonce replay: this nonce already belongs to another transaction');
  }

  // 5. Idempotency vs conflict, keyed on transactionId. Both devices push
  //    their copy of the same payment: the second copy must be ACKed, not
  //    double-credited. Identical content = DUPLICATE (server already has
  //    it). Different content under the same id = CONFLICT: one side
  //    altered the transaction - first accepted copy wins, forever.
  const existing = await Transaction.findOne({ transactionId: id });
  if (existing) {
    const identical = canonicalPayload(existing) === canonicalPayload(tx);
    if (identical) {
      return {
        transactionId: id,
        outcome: 'DUPLICATE',
        serverStatus: existing.status,
        reason: null,
      };
    }
    return {
      transactionId: id,
      outcome: 'CONFLICT',
      serverStatus: existing.status,
      reason: 'a DIFFERENT transaction with this id was already accepted; the first one was kept',
    };
  }

  // 6. Accept. Phase 6 stores CONFIRMED immediately after these checks;
  //    Phase 7 inserts the balance-arbitration gate before this point.
  const doc = new Transaction({
    transactionId: tx.transactionId,
    senderId: tx.senderId,
    receiverId: tx.receiverId,
    senderWalletId: tx.senderWalletId,
    receiverWalletId: tx.receiverWalletId,
    amount: tx.amount,
    type: tx.type,
    status: 'CONFIRMED',
    description: tx.description ?? 'Synced offline payment',
    nonce: tx.nonce ?? null,
    senderPublicKey: tx.senderPublicKey ?? null,
    signature: tx.signature ?? null,
    timestamp: tx.timestamp ? new Date(tx.timestamp) : new Date(),
  });

  try {
    await doc.save();
  } catch (error) {
    if (error.code === 11000) {
      // Lost a race between findOne and save: another request stored this
      // transactionId (or nonce) first. Re-read and answer as duplicate /
      // replay - NEVER store or credit twice.
      const winner = await Transaction.findOne({ transactionId: id });
      if (winner) {
        return {
          transactionId: id,
          outcome: 'DUPLICATE',
          serverStatus: winner.status,
          reason: null,
        };
      }
      return rejected('nonce replay: this nonce already belongs to another transaction');
    }
    throw error;
  }

  // Keep the server-side balances of KNOWN users moving, so Phase 7 has a
  // ledger to arbitrate against. No insufficiency check on purpose (Phase 7).
  const receiver = usersById.get(tx.receiverId);
  if (sender) sender.balance -= tx.amount;
  if (receiver) receiver.balance += tx.amount;
  const dirty = [sender, receiver].filter(Boolean);
  if (dirty.length > 0) await Promise.all(dirty.map((u) => u.save()));

  return {
    transactionId: id,
    outcome: 'CONFIRMED',
    serverStatus: 'CONFIRMED',
    reason: null,
  };
}

/**
 * POST /api/sync/push
 * body: { userId?, publicKey?, transactions: [tx, ...] }
 *
 * Always HTTP 200 for a well-formed batch - the per-transaction verdicts
 * live in data.results (a rejected transaction must not hide the fate of
 * the other 49 in the same upload).
 */
export const pushTransactions = async (req, res) => {
  try {
    const { userId, publicKey, transactions } = req.body ?? {};

    if (!Array.isArray(transactions) || transactions.length === 0) {
      return res.status(400).json({
        success: false,
        error: 'transactions must be a non-empty array',
      });
    }
    if (transactions.length > MAX_BATCH) {
      return res.status(400).json({
        success: false,
        error: `batch too large (max ${MAX_BATCH} transactions per push)`,
      });
    }

    const registration = await registerKey(userId, publicKey);

    // Load every involved user once - binding checks and balance updates
    // both need them, and one query per transaction would be silly.
    const userIds = [
      ...new Set(
        transactions.flatMap((t) => [t?.senderId, t?.receiverId]).filter(Boolean),
      ),
    ];
    const users = await User.find({ userId: { $in: userIds } });
    const usersById = new Map(users.map((u) => [u.userId, u]));

    const results = [];
    for (const tx of transactions) {
      results.push(await adjudicate(tx, usersById));
    }

    res.status(200).json({
      success: true,
      data: {
        registration,
        results,
        serverTime: new Date().toISOString(),
      },
    });
  } catch (error) {
    console.error('Sync push error:', error);
    res.status(500).json({ success: false, error: 'Internal server error' });
  }
};

/**
 * POST /api/sync/pull
 * body: { userId, since? }   (since = ISO timestamp, optional incremental sync)
 *
 * Returns every stored transaction involving this user - including ones
 * the OTHER device uploaded while we were offline. Phase 7 will add
 * authoritative conflict verdicts to this stream as well.
 */
export const pullTransactions = async (req, res) => {
  try {
    const { userId, since } = req.body ?? {};
    if (!userId) {
      return res.status(400).json({ success: false, error: 'userId is required' });
    }

    const filter = { $or: [{ senderId: userId }, { receiverId: userId }] };
    if (since) {
      const sinceDate = new Date(since);
      if (Number.isNaN(sinceDate.getTime())) {
        return res.status(400).json({ success: false, error: 'since must be an ISO timestamp' });
      }
      filter.timestamp = { $gt: sinceDate };
    }

    const transactions = await Transaction.find(filter)
      .sort({ timestamp: 1 })
      .limit(500);

    res.status(200).json({
      success: true,
      data: {
        transactions: transactions.map(toWire),
        serverTime: new Date().toISOString(),
      },
    });
  } catch (error) {
    console.error('Sync pull error:', error);
    res.status(500).json({ success: false, error: 'Internal server error' });
  }
};
