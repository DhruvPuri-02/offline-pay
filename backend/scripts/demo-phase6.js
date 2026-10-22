// Phase 6 demo + self-checking test: the REAL sync endpoints, over real
// HTTP, against an in-memory MongoDB. No mocked controllers.
//
// It also closes the loop with Phase 5: every transaction below is signed
// with Node crypto using the SAME fixed key seed as the Dart/Node interop
// vector (backend/scripts/test-signature.js) - so "the app signs, the
// server verifies" is exercised end to end.
//
// Run: npm run test:phase6

import assert from 'node:assert/strict';
import crypto from 'node:crypto';

import connectDB, { disconnectDB } from '../src/config/database.js';
import app from '../src/app.js';
import { canonicalPayload } from '../src/utils/transactionSignature.js';

// ---------------------------------------------------------------------------
// The fixed signing identity shared with Phase 5's interop vector.
// ---------------------------------------------------------------------------
const SEED = Buffer.from('AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=', 'base64');

// Raw 32-byte Ed25519 seed -> PKCS8 DER, the standard wrapper node:crypto
// needs (prefix defined by RFC 8410 - not our invention). The SPKI
// equivalent prefix is 12 bytes and is stripped from exports below.
const PKCS8_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex');

const ALICE_PRIVATE = crypto.createPrivateKey({
  key: Buffer.concat([PKCS8_PREFIX, SEED]),
  format: 'der',
  type: 'pkcs8',
});
// Derive the matching raw public key. Ed25519 SPKI stores the 32-byte
// PUBLIC key directly (no derivation happens on import) - so we must go
// through the private key to have Node compute it for us.
const ALICE_PUBLIC_B64 = crypto
  .createPublicKey(ALICE_PRIVATE)
  .export({ format: 'der', type: 'spki' })
  .subarray(12)
  .toString('base64');
assert.equal(
  ALICE_PUBLIC_B64,
  'A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=',
  'fixed seed must derive the known Phase 5 interop public key',
);

// A second identity - "Mallory" - generated randomly, used to prove that a
// self-consistent signature from an UNREGISTERED key is still refused.
const MALLORY = crypto.generateKeyPairSync('ed25519');
const MALLORY_PUBLIC_B64 = MALLORY.publicKey
  .export({ format: 'der', type: 'spki' })
  .subarray(12)
  .toString('base64');

const signWithAlice = (tx) =>
  crypto
    .sign(null, Buffer.from(canonicalPayload(tx), 'utf8'), ALICE_PRIVATE)
    .toString('base64');
const signWithMallory = (tx) =>
  crypto
    .sign(null, Buffer.from(canonicalPayload(tx), 'utf8'), MALLORY.privateKey)
    .toString('base64');

/** Build a wire-shaped transaction like the app's Transaction.toJson(). */
function makeTx({ id, senderId, receiverId, amount, nonce, timestamp, description }) {
  return {
    transactionId: id,
    senderId,
    receiverId,
    senderWalletId: `WALLET_${senderId}`,
    receiverWalletId: `WALLET_${receiverId}`,
    amount,
    type: 'OFFLINE_PAYMENT',
    status: 'PENDING_SYNC',
    description,
    nonce,
    senderPublicKey: ALICE_PUBLIC_B64,
    signature: null, // filled by signWithAlice / signWithMallory
    timestamp,
  };
}

const signedByAlice = (tx) => ({ ...tx, signature: signWithAlice(tx) });

// ---------------------------------------------------------------------------
// Tiny check harness (same style as test-signature.js)
// ---------------------------------------------------------------------------
let failed = false;
function check(name, fn) {
  try {
    fn();
    console.log(`  ok - ${name}`);
  } catch (error) {
    failed = true;
    console.error(`  FAIL - ${name}`);
    console.error(`         ${error.message}`);
  }
}

const resultFor = (body, transactionId) =>
  body.data.results.find((r) => r.transactionId === transactionId);

async function main() {
  await connectDB();
  const server = app.listen(0); // ephemeral port - no clashes with a dev server
  const port = server.address().port;
  const api = `http://127.0.0.1:${port}/api`;

  const post = async (path, body) => {
    const response = await fetch(`${api}${path}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    return { status: response.status, body: await response.json() };
  };

  try {
    console.log('Phase 6 sync demo (real endpoints, real signatures):');

    // Alice and Bob exist server-side (Phase 1 onboarding). Their server
    // balances are what Phase 7 will arbitrate against.
    const aliceRes = await post('/users', {
      username: 'alice_sync',
      name: 'Alice',
      initialBalance: 1000,
    });
    const bobRes = await post('/users', {
      username: 'bob_sync',
      name: 'Bob',
      initialBalance: 1000,
    });
    const alice = aliceRes.body.data;
    const bob = bobRes.body.data;

    // A signed payment made OFFLINE between the two devices.
    const tx1 = signedByAlice(
      makeTx({
        id: 'TXN_sync_0001',
        senderId: alice.userId,
        receiverId: bob.userId,
        amount: 100,
        nonce: 'nonce_sync_0001',
        timestamp: '2026-01-15T10:00:00.000Z',
        description: 'Offline chai',
      }),
    );

    // ---- 1. first push: bound key, confirmed, balances moved -----------
    const push1 = await post('/sync/push', {
      userId: alice.userId,
      publicKey: ALICE_PUBLIC_B64,
      transactions: [tx1],
    });
    check('push of a genuine signed payment returns 200', () => {
      assert.equal(push1.status, 200);
    });
    check('Alice\'s key is bound to her user on first push (TOFU)', () => {
      assert.equal(push1.body.data.registration, 'bound');
    });
    check('the payment is CONFIRMED', () => {
      assert.equal(resultFor(push1.body, tx1.transactionId).outcome, 'CONFIRMED');
    });
    const aliceView1 = await (await fetch(`${api}/users/${alice.userId}`)).json();
    const bobView1 = await (await fetch(`${api}/users/${bob.userId}`)).json();
    check('server balances moved: Alice 1000->900, Bob 1000->1100', () => {
      assert.equal(aliceView1.data.balance, 900);
      assert.equal(bobView1.data.balance, 1100);
    });

    // ---- 2. re-push of the same copy: idempotent duplicate -------------
    const push2 = await post('/sync/push', { transactions: [tx1] });
    check('re-pushing the identical copy reports DUPLICATE (idempotent)', () => {
      assert.equal(resultFor(push2.body, tx1.transactionId).outcome, 'DUPLICATE');
    });
    const aliceView2 = await (await fetch(`${api}/users/${alice.userId}`)).json();
    check('no double-credit: balances unchanged after duplicate', () => {
      assert.equal(aliceView2.data.balance, 900);
    });

    // ---- 3. tampered amount: signature fails --------------------------
    const tampered = { ...tx1, amount: 999, transactionId: 'TXN_sync_tamper' };
    const push3 = await post('/sync/push', { transactions: [tampered] });
    check('amount edited after signing is REJECTED (invalid signature)', () => {
      const r = resultFor(push3.body, tampered.transactionId);
      assert.equal(r.outcome, 'REJECTED');
      assert.match(r.reason, /invalid signature/);
    });

    // ---- 4. registered key enforced ------------------------------------
    const malloryBase = makeTx({
      id: 'TXN_sync_0004',
      senderId: alice.userId,
      receiverId: bob.userId,
      amount: 50,
      nonce: 'nonce_sync_0004',
      timestamp: '2026-01-15T11:00:00.000Z',
      description: 'Signed by a different key',
    });
    const malloryTx = {
      ...malloryBase,
      senderPublicKey: MALLORY_PUBLIC_B64,
      signature: signWithMallory(malloryBase),
    };
    const push4 = await post('/sync/push', { transactions: [malloryTx] });
    check('a self-consistent signature from an UNREGISTERED key is REJECTED', () => {
      const r = resultFor(push4.body, malloryTx.transactionId);
      assert.equal(r.outcome, 'REJECTED');
      assert.match(r.reason, /public key mismatch/);
    });

    // ---- 5. unsigned offline payment refused ---------------------------
    const unsigned = makeTx({
      id: 'TXN_sync_0005',
      senderId: alice.userId,
      receiverId: bob.userId,
      amount: 10,
      nonce: 'nonce_sync_0005',
      timestamp: '2026-01-15T12:00:00.000Z',
      description: 'No signature at all',
    });
    const push5 = await post('/sync/push', { transactions: [unsigned] });
    check('unsigned offline payments are REJECTED', () => {
      const r = resultFor(push5.body, unsigned.transactionId);
      assert.equal(r.outcome, 'REJECTED');
      assert.match(r.reason, /unsigned/);
    });

    // ---- 6. nonce replay under a new id --------------------------------
    const tx6 = signedByAlice(
      makeTx({
        id: 'TXN_sync_0006',
        senderId: alice.userId,
        receiverId: bob.userId,
        amount: 25,
        nonce: 'nonce_sync_0006',
        timestamp: '2026-01-15T13:00:00.000Z',
        description: 'Genuine first use of this nonce',
      }),
    );
    const push6 = await post('/sync/push', { transactions: [tx6] });
    check('a second genuine payment is CONFIRMED', () => {
      assert.equal(resultFor(push6.body, tx6.transactionId).outcome, 'CONFIRMED');
    });
    const replay = signedByAlice(
      makeTx({
        id: 'TXN_sync_0007', // different id...
        senderId: alice.userId,
        receiverId: bob.userId,
        amount: 25,
        nonce: 'nonce_sync_0006', // ...same nonce: a replay attempt
        timestamp: '2026-01-15T13:05:00.000Z',
        description: 'Replayed nonce',
      }),
    );
    const push7 = await post('/sync/push', { transactions: [replay] });
    check('reusing a nonce under a new id is REJECTED (replay)', () => {
      const r = resultFor(push7.body, replay.transactionId);
      assert.equal(r.outcome, 'REJECTED');
      assert.match(r.reason, /nonce replay/);
    });

    // ---- 7. conflicting content under an accepted id -------------------
    const conflicting = signedByAlice(
      makeTx({
        id: 'TXN_sync_0001', // tx1's id...
        senderId: alice.userId,
        receiverId: bob.userId,
        amount: 999, // ...but different details
        nonce: 'nonce_sync_conflict',
        timestamp: '2026-01-15T10:00:00.000Z',
        description: 'Conflicting copy',
      }),
    );
    const push8 = await post('/sync/push', { transactions: [conflicting] });
    check('same id + different content is CONFLICT (first copy kept)', () => {
      const r = resultFor(push8.body, conflicting.transactionId);
      assert.equal(r.outcome, 'CONFLICT');
    });

    // ---- 8. batch answers every transaction individually ---------------
    const mixed = await post('/sync/push', {
      transactions: [tx1, unsigned],
    });
    check('one bad transaction does not hide the fate of the good one', () => {
      assert.equal(resultFor(mixed.body, tx1.transactionId).outcome, 'DUPLICATE');
      assert.equal(resultFor(mixed.body, unsigned.transactionId).outcome, 'REJECTED');
    });

    // ---- 9. pull: what the server knows about Alice --------------------
    const pullAlice = await post('/sync/pull', { userId: alice.userId });
    // Note: creating a server user also writes a welcome TOPUP transaction,
    // so we filter to the fixtures this demo controls.
    check('pull returns Alice\'s accepted payments with statuses', () => {
      const ids = pullAlice.body.data.transactions
        .map((t) => t.transactionId)
        .filter((id) => id.startsWith('TXN_sync'))
        .sort();
      assert.deepEqual(ids, ['TXN_sync_0001', 'TXN_sync_0006']);
      const syncTxs = pullAlice.body.data.transactions.filter((t) =>
        t.transactionId.startsWith('TXN_sync'),
      );
      assert.ok(syncTxs.every((t) => t.status === 'CONFIRMED'));
    });
    const pullSince = await post('/sync/pull', {
      userId: alice.userId,
      since: '2026-01-15T12:30:00.000Z',
    });
    check('incremental pull (since) returns only the newer payment', () => {
      const ids = pullSince.body.data.transactions
        .map((t) => t.transactionId)
        .filter((id) => id.startsWith('TXN_sync'));
      assert.deepEqual(ids, ['TXN_sync_0006']);
    });
    const pullBob = await post('/sync/pull', { userId: bob.userId });
    check('Bob pulls the payments made to him (uploaded by Alice\'s device)', () => {
      const ids = pullBob.body.data.transactions
        .map((t) => t.transactionId)
        .filter((id) => id.startsWith('TXN_sync'))
        .sort();
      assert.deepEqual(ids, ['TXN_sync_0001', 'TXN_sync_0006']);
    });

    // ---- 10. key stays bound -------------------------------------------
    const push9 = await post('/sync/push', {
      userId: alice.userId,
      publicKey: ALICE_PUBLIC_B64,
      transactions: [tx1],
    });
    check('later pushes report the key as already-bound', () => {
      assert.equal(push9.body.data.registration, 'already-bound');
    });

    if (failed) {
      console.error('\nPhase 6 sync: FAILED');
      process.exitCode = 1;
    } else {
      console.log('\nPhase 6 sync: all checks passed.');
    }
  } finally {
    server.close();
    await disconnectDB();
  }
}

main().catch((error) => {
  console.error('Phase 6 demo crashed:', error);
  process.exitCode = 1;
});
