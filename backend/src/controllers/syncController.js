// Phase 6: offline synchronization. Phase 7: server-side balance
// arbitration - the authoritative half of double-spend prevention.
//
// Devices do TWO things here:
//
//   POST /api/sync/push  - upload their PENDING_SYNC queue. The server is
//                          the ledger authority: it verifies signatures,
//                          checks each spend against the sender's
//                          authoritative balance, stores each transaction
//                          ONCE (idempotent by transactionId), refuses
//                          replays (nonce reuse), and reports a
//                          per-transaction outcome the device applies to
//                          its local SQLite ledger.
//
//   POST /api/sync/pull  - download everything the server knows about the
//                          calling user: payments uploaded by the OTHER
//                          device while this one was offline, plus their
//                          statuses.
//
// Phase 7 added, on top of Phase 6:
//   * ONBOARDING - a device whose userId is unknown creates the account
//     on its first push, starting from a SERVER-decided grant plus any
//     payments already escrowed for it (the client cannot declare its
//     own opening balance, or "I am rich" would defeat everything below);
//   * THE BALANCE GATE - a spend the sender cannot cover is REJECTED with
//     code INSUFFICIENT_BALANCE instead of driving the account negative.
//     This is what stops a cloned wallet: clones share ONE server
//     balance, so the server lets the FIRST spend through and refuses
//     every later one, no matter which clone pushes it;
//   * TYPE + LIMIT gates - clients may only push OFFLINE_PAYMENT rows
//     within the app's per-transaction offline cap (top-ups are minted
//     server-side only; a modifiable client cannot set its own policy);
//   * the pushing device's post-batch `balance` in the response, so a
//     device whose local view drifted can correct itself.
//
// Still NOT here (honest scope, see docs/OFFLINE_FIRST.md section 8):
// no authentication - anyone who can reach the server may claim any
// userId (trust-on-first-use, first claim wins) - and the balance check
// is read-then-write rather than one atomic database operation, so two
// truly simultaneous pushes could race. The app syncs serially; a
// production system would use atomic conditional updates.

import Transaction from '../models/Transaction.js';
import User from '../models/User.js';
import { canonicalPayload, verifyReceiptSignature } from '../utils/transactionSignature.js';

// Sanity cap: a phone's offline queue is small; a huge batch smells wrong.
const MAX_BATCH = 200;

// Phase 7: the server's own copy of the app's offline spending rules
// (mobile/lib/providers/wallet_provider.dart). Mirrored here because the
// client can be modified: a limit only the client enforces is not policy.
const MAX_OFFLINE_AMOUNT = 500;

// Phase 7: opening balance granted when a device onboards an unknown
// userId. Deliberately a SERVER constant equal to the app's demo seed
// (firstRunSeedBalance = 500), so both sides agree on where the money
// came from while only the server decides how much it is.
const ONBOARDING_BALANCE = 500;

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
 * Deterministic, schema-safe username for an onboarded device.
 *
 * userIds are server-unique, so a stable transform of one is unique too.
 * The FNV-1a hash suffix covers pathological claims: there is no auth, so
 * anyone may push ANY userId (long, hostile, or crafted to collide after
 * sanitizing). username is capped at 30 chars by the User schema.
 */
function syncUsername(userId) {
  const sanitized = userId.toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 16);
  let hash = 0x811c9dc5; // FNV-1a
  for (const ch of userId) hash = Math.imul(hash ^ ch.charCodeAt(0), 0x01000193);
  return `sync_${sanitized}_${(hash >>> 0).toString(16).padStart(8, '0')}`;
}

/**
 * Phase 7 onboarding: a push from an unknown userId creates the account.
 *
 *   balance = SERVER-side opening grant + every confirmed payment already
 *             stored for this user.
 *
 * That second term is escrow: when Alice paid Bob before Bob ever synced,
 * the server accepted the payment (debiting Alice) but had no account to
 * credit - the money waits here and lands the moment Bob's device shows
 * up. Note what is deliberately ABSENT: no welcome transaction row. The
 * device already has its own local seed top-up explaining the same money;
 * writing a server-side copy would make the device double-count it on the
 * next pull.
 */
async function onboardUser(userId, publicKey) {
  const escrow = await Transaction.aggregate([
    { $match: { receiverId: userId, status: 'CONFIRMED' } },
    { $group: { _id: null, total: { $sum: '$amount' } } },
  ]);
  const user = new User({
    userId,
    username: syncUsername(userId),
    name: 'Synced device',
    walletId: `SYNCW_${userId}`,
    balance: ONBOARDING_BALANCE + (escrow[0]?.total ?? 0),
    publicKey: publicKey ?? null,
  });
  await user.save();
  return user;
}

/**
 * Bind the pushing device's public key to its user - trust on first use,
 * and (Phase 7) create the user itself on first contact.
 *
 * This is what completes Phase 5's trust story: after a key is bound,
 * receipts signed by ANY OTHER key cannot be pushed as that sender
 * ("public key mismatch" below). It is still TOFU: there is no login, so
 * the FIRST claim on a userId wins - account, grant and key alike. A
 * bound key is NEVER overwritten here - rotation needs an authenticated
 * flow this prototype deliberately does not have.
 */
async function registerKey(userId, publicKey) {
  if (!userId) return 'not-provided';

  let user = await User.findOne({ userId });
  if (!user) {
    await onboardUser(userId, publicKey);
    return 'created';
  }

  if (!publicKey) return 'not-provided';
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
  // `reason` is for humans (tests and the app's history show it verbatim);
  // `code` is the stable value the app reacts to (e.g. INSUFFICIENT_BALANCE
  // triggers a local balance correction - see sync_service.dart).
  const rejected = (reason, code = null) => ({
    transactionId: id,
    outcome: 'REJECTED',
    serverStatus: 'REJECTED',
    reason,
    code,
  });

  // 1. Shape. Malformed input is refused wholesale, not guessed at.
  const missing = REQUIRED_FIELDS.filter(
    (field) => tx?.[field] === undefined || tx?.[field] === null,
  );
  if (missing.length > 0) return rejected(`malformed: missing ${missing.join(', ')}`, 'MALFORMED');
  // typeof guard: a string amount survives `Number()` checks but corrupts
  // the balance arithmetic below (`500 + "100"` = "500100" in JS).
  if (typeof tx.amount !== 'number' || !Number.isFinite(tx.amount) || tx.amount <= 0) {
    return rejected('malformed: amount must be a positive number', 'MALFORMED');
  }

  // 2. Signature (Phase 5, enforced server-side now). Offline payments are
  //    always signed by the payer; unsigned ones come only from broken or
  //    hostile clients. A signature that exists but does not match the
  //    uploaded fields means the receipt was tampered with in transit.
  if (tx.type === 'OFFLINE_PAYMENT') {
    if (!tx.signature || !tx.senderPublicKey) {
      return rejected('unsigned offline payment', 'UNSIGNED');
    }
  }
  if ((tx.signature || tx.senderPublicKey) && !verifyReceiptSignature(tx)) {
    return rejected(
      'invalid signature: the transaction does not match what the payer signed',
      'INVALID_SIGNATURE',
    );
  }

  // 3. Key binding: if the SENDER has a registered key, this transaction
  //    must be signed by THAT key - not merely by some self-consistent one.
  const sender = usersById.get(tx.senderId);
  if (sender?.publicKey && tx.senderPublicKey && sender.publicKey !== tx.senderPublicKey) {
    return rejected(
      'public key mismatch: signed with a key that is not registered for this sender',
      'KEY_MISMATCH',
    );
  }

  // 4. Replay protection: a nonce may only ever belong to ONE transaction.
  //    (Same nonce + same transactionId is handled as a duplicate below.)
  if (typeof tx.nonce === 'string') {
    const reused = await Transaction.findOne({
      nonce: tx.nonce,
      transactionId: { $ne: id },
    });
    if (reused) {
      return rejected('nonce replay: this nonce already belongs to another transaction', 'NONCE_REPLAY');
    }
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
        code: null,
      };
    }
    return {
      transactionId: id,
      outcome: 'CONFLICT',
      serverStatus: existing.status,
      reason: 'a DIFFERENT transaction with this id was already accepted; the first one was kept',
      code: null,
    };
  }

  // 6. Phase 7 gates. Signature, key, replay and idempotency above already
  //    ran: we do not arbitrate money for input we would refuse anyway.

  // 6a. Clients upload offline payments, full stop. Top-ups and transfers
  //     are minted server-side through the REST APIs - accepting a client
  //     TOPUP here would let any app print money by pushing one to itself.
  if (tx.type !== 'OFFLINE_PAYMENT') {
    return rejected(
      'only offline payments may be pushed: top-ups and transfers are created server-side',
      'NOT_OFFLINE_PAYMENT',
    );
  }

  // 6b. The app caps one offline payment; so does the server. The client
  //     is modifiable, so a limit only it enforces is not a limit.
  if (tx.amount > MAX_OFFLINE_AMOUNT) {
    return rejected(
      `exceeds the offline spending limit of ${MAX_OFFLINE_AMOUNT} per transaction`,
      'OVER_LIMIT',
    );
  }

  // 6c. Somebody must exist to be debited. The pusher is always onboarded
  //     by now; anything else is an unregistered sender whose balance this
  //     server cannot know (and whose key it cannot bind).
  if (!sender) {
    return rejected('sender is not registered on this server', 'SENDER_NOT_REGISTERED');
  }

  // 6d. THE double-spend gate: would this spend exceed the sender's
  //     authoritative balance? A cloned wallet shares ONE server balance
  //     with its twin, so the first spend wins and every later one is
  //     refused here - whichever clone pushes it. Checked against the
  //     running balance, so several spends in ONE batch debit in order.
  if (tx.amount > sender.balance) {
    return rejected(
      `insufficient balance on the server: sender has ${sender.balance}, transaction needs ${tx.amount}`,
      'INSUFFICIENT_BALANCE',
    );
  }

  // 7. Accept: store as CONFIRMED, then move the server-side balances.
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
          code: null,
        };
      }
      return rejected('nonce replay: this nonce already belongs to another transaction', 'NONCE_REPLAY');
    }
    throw error;
  }

  // Move the server-side balances. Phase 7: the gate in 6d guarantees the
  // debit cannot go negative (User.balance also carries schema min: 0 as
  // a backstop). An unknown RECEIVER is not a problem either - their
  // credit is escrowed and lands at THEIR onboarding (onboardUser).
  const receiver = usersById.get(tx.receiverId);
  sender.balance -= tx.amount;
  if (receiver) receiver.balance += tx.amount;
  const dirty = [sender, receiver].filter(Boolean);
  if (dirty.length > 0) await Promise.all(dirty.map((u) => u.save()));

  return {
    transactionId: id,
    outcome: 'CONFIRMED',
    serverStatus: 'CONFIRMED',
    reason: null,
    code: null,
  };
}

/**
 * POST /api/sync/push
 * body: { userId?, publicKey?, transactions: [tx, ...] }
 *
 * Always HTTP 200 for a well-formed batch - the per-transaction verdicts
 * live in data.results (a rejected transaction must not hide the fate of
 * the other 49 in the same upload).
 *
 * Phase 7: `data.balance` is the pushing user's authoritative balance
 * AFTER the whole batch (null when no userId was claimed). It is what a
 * device whose local view drifted - a clone whose twin spent first - uses
 * to correct itself (see the app's sync_service.dart).
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

    // Load every involved user once - binding checks, balance arbitration
    // and balance updates all need them, and one query per transaction
    // would be silly. The PUSHER is included even when none of the batch
    // is theirs, so the response can always state their balance.
    const userIds = [
      ...new Set(
        [userId, ...transactions.flatMap((t) => [t?.senderId, t?.receiverId])].filter(Boolean),
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
        balance: userId ? (usersById.get(userId)?.balance ?? null) : null,
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
 * the OTHER device uploaded while we were offline. The server only ever
 * stores what it CONFIRMED (Phase 7 arbitration), so everything here is
 * authoritative money the caller is entitled to see; the device still
 * re-verifies signatures on arrival before merging.
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
