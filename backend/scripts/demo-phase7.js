// Phase 7 demo + self-checking test: server-side BALANCE ARBITRATION over
// real HTTP, against an in-memory MongoDB. No mocked controllers.
//
// The headline check is the cloned wallet: two devices claiming the same
// userId share ONE server balance, so the server confirms the first spend
// and refuses the rest - double-spend protection is finally AUTHORITATIVE
// instead of (honestly) absent, as documented through Phase 6.
//
// Every transaction is signed with Node crypto using the SAME fixed key
// seed as the Dart/Node interop vector (scripts/test-signature.js), so
// "the app signs, the server verifies, the ledger arbitrates" runs end to
// end.
//
// Run: npm run test:phase7

import assert from 'node:assert/strict';
import crypto from 'node:crypto';

import connectDB, { disconnectDB } from '../src/config/database.js';
import app from '../src/app.js';
import { canonicalPayload } from '../src/utils/transactionSignature.js';

// ---------------------------------------------------------------------------
// The fixed signing identity shared with Phase 5's interop vector (Alice),
// plus throwaway identities for the other roles in this script.
// ---------------------------------------------------------------------------
const SEED = Buffer.from('AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=', 'base64');
const PKCS8_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex');

const ALICE_PRIVATE = crypto.createPrivateKey({
  key: Buffer.concat([PKCS8_PREFIX, SEED]),
  format: 'der',
  type: 'pkcs8',
});
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

// Mallory: signs a fully self-consistent transaction for a sender that the
// server has never heard of (proves a valid signature is not existence).
const MALLORY = crypto.generateKeyPairSync('ed25519');
// Carol and Dave: devices that onboard THEIR OWN accounts on first push.
const CAROL = crypto.generateKeyPairSync('ed25519');
const DAVE = crypto.generateKeyPairSync('ed25519');

const rawPub = (pair) =>
  pair.publicKey.export({ format: 'der', type: 'spki' }).subarray(12).toString('base64');

const signWith = (privateKey, tx) =>
  crypto.sign(null, Buffer.from(canonicalPayload(tx), 'utf8'), privateKey).toString('base64');

/** Build a wire-shaped transaction like the app's Transaction.toJson(). */
function makeTx({ id, senderId, receiverId, amount, nonce, timestamp, description, publicKey }) {
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
    senderPublicKey: publicKey ?? ALICE_PUBLIC_B64,
    signature: null,
    timestamp,
  };
}

const signedWith = (privateKey, tx) => ({ ...tx, signature: signWith(privateKey, tx) });
const signedByAlice = (tx) => signedWith(ALICE_PRIVATE, tx);

// ---------------------------------------------------------------------------
// Tiny check harness (async so balance fetches can live INSIDE checks -
// an assertion outside a check would crash instead of reporting cleanly)
// ---------------------------------------------------------------------------
let failed = false;
async function check(name, fn) {
  try {
    await fn();
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
  const balanceOf = async (userId) => {
    const view = await (await fetch(`${api}/users/${userId}`)).json();
    return view.data.balance;
  };

  try {
    console.log('Phase 7 balance-arbitration demo (real endpoints, real signatures):');

    // =====================================================================
    // A. A REST-created user (initialBalance 700) is arbitrated on sync.
    //    Amounts stay under the 500 offline cap so the BALANCE gate - not
    //    the limit gate - is what decides.
    // =====================================================================
    const aliceRes = await post('/users', {
      username: 'alice_arb',
      name: 'Alice',
      initialBalance: 700,
    });
    const alice = aliceRes.body.data;

    const txAffordable = signedByAlice(
      makeTx({
        id: 'TXN_p7_0001',
        senderId: alice.userId,
        receiverId: 'USER_someone_else',
        amount: 450,
        nonce: 'nonce_p7_0001',
        timestamp: '2026-02-10T09:00:00.000Z',
        description: 'Within her 700 balance',
      }),
    );
    const push1 = await post('/sync/push', {
      userId: alice.userId,
      publicKey: ALICE_PUBLIC_B64,
      transactions: [txAffordable],
    });
    await check('an affordable spend is CONFIRMED and the response states the balance', () => {
      assert.equal(push1.status, 200);
      assert.equal(resultFor(push1.body, txAffordable.transactionId).outcome, 'CONFIRMED');
      assert.equal(push1.body.data.balance, 250);
    });
    await check('the server balance actually moved: 700 -> 250', async () => {
      assert.equal(await balanceOf(alice.userId), 250);
    });

    const txUnaffordable = signedByAlice(
      makeTx({
        id: 'TXN_p7_0002',
        senderId: alice.userId,
        receiverId: 'USER_someone_else',
        amount: 500, // within the cap, but more than the 250 left
        nonce: 'nonce_p7_0002',
        timestamp: '2026-02-10T09:05:00.000Z',
        description: 'More than she has left',
      }),
    );
    const push2 = await post('/sync/push', {
      userId: alice.userId,
      publicKey: ALICE_PUBLIC_B64,
      transactions: [txUnaffordable],
    });
    const r2 = resultFor(push2.body, txUnaffordable.transactionId);
    await check('an unaffordable spend is REJECTED with code INSUFFICIENT_BALANCE', () => {
      assert.equal(push2.status, 200); // 200, not 500: arbitration is an ANSWER
      assert.equal(r2.outcome, 'REJECTED');
      assert.equal(r2.code, 'INSUFFICIENT_BALANCE');
      assert.match(r2.reason, /insufficient balance on the server/);
    });
    await check('the refusal did not move the balance (still 250)', async () => {
      assert.equal(push2.body.data.balance, 250);
      assert.equal(await balanceOf(alice.userId), 250);
    });

    // ---- A3: several spends in ONE batch debit in order -----------------
    const batch = [150, 200, 300].map((amount, i) =>
      signedByAlice(
        makeTx({
          id: `TXN_p7_0003_${i}`,
          senderId: alice.userId,
          receiverId: 'USER_someone_else',
          amount,
          nonce: `nonce_p7_0003_${i}`,
          timestamp: `2026-02-10T09:1${i}:00.000Z`,
          description: `Batch spend ${i}`,
        }),
      ),
    );
    const push3 = await post('/sync/push', {
      userId: alice.userId,
      publicKey: ALICE_PUBLIC_B64,
      transactions: batch,
    });
    await check('a batch debits cumulatively: 150 ok, then 200 and 300 exceed 100', () => {
      assert.deepEqual(
        batch.map((tx) => resultFor(push3.body, tx.transactionId).outcome),
        ['CONFIRMED', 'REJECTED', 'REJECTED'],
      );
      assert.equal(push3.body.data.balance, 100);
    });

    // ---- A4: idempotent re-push must NOT debit again --------------------
    const push4 = await post('/sync/push', {
      userId: alice.userId,
      publicKey: ALICE_PUBLIC_B64,
      transactions: [batch[0]],
    });
    await check('re-pushing a confirmed spend is DUPLICATE - no double debit', async () => {
      assert.equal(resultFor(push4.body, batch[0].transactionId).outcome, 'DUPLICATE');
      assert.equal(push4.body.data.balance, 100);
      assert.equal(await balanceOf(alice.userId), 100);
    });

    // =====================================================================
    // B. THE CLONE: a second device, same userId, same (copied) key.
    // =====================================================================
    const cloneTx = signedByAlice(
      makeTx({
        id: 'TXN_p7_clone_1',
        senderId: alice.userId,
        receiverId: 'USER_clone_target',
        amount: 300, // the twin's own ledger says it can afford this...
        nonce: 'nonce_p7_clone_1',
        timestamp: '2026-02-10T10:00:00.000Z',
        description: 'The twin tries to spend the same money',
      }),
    );
    const clonePush = await post('/sync/push', {
      userId: alice.userId, // claims the SAME account...
      publicKey: ALICE_PUBLIC_B64, // ...with the SAME copied key: passes TOFU
      transactions: [cloneTx],
    });
    await check('the clone passes signature/key checks but cannot overspend 300 > 100', () => {
      const r = resultFor(clonePush.body, cloneTx.transactionId);
      assert.equal(r.outcome, 'REJECTED');
      assert.equal(r.code, 'INSUFFICIENT_BALANCE');
    });
    await check('total outflow stayed capped: balance is still 100, not -200', async () => {
      assert.equal(clonePush.body.data.balance, 100);
      assert.equal(await balanceOf(alice.userId), 100);
    });

    // =====================================================================
    // C. Policy gates (the client is modifiable - the server is not).
    // =====================================================================
    const forgedTopup = {
      transactionId: 'TXN_p7_topup',
      senderId: 'SYSTEM',
      receiverId: alice.userId,
      senderWalletId: 'SYSTEM',
      receiverWalletId: `WALLET_${alice.userId}`,
      amount: 999999,
      type: 'TOPUP',
      status: 'PENDING_SYNC',
      description: 'Printing money',
      nonce: 'nonce_p7_topup',
      senderPublicKey: null,
      signature: null,
      timestamp: '2026-02-10T11:00:00.000Z',
    };
    const topupPush = await post('/sync/push', {
      userId: alice.userId,
      transactions: [forgedTopup],
    });
    await check('a client-pushed TOPUP is refused (top-ups are minted server-side)', () => {
      const r = resultFor(topupPush.body, forgedTopup.transactionId);
      assert.equal(r.outcome, 'REJECTED');
      assert.equal(r.code, 'NOT_OFFLINE_PAYMENT');
      assert.match(r.reason, /only offline payments/);
    });

    const overLimit = signedByAlice(
      makeTx({
        id: 'TXN_p7_overlimit',
        senderId: alice.userId,
        receiverId: 'USER_someone_else',
        amount: 600, // over the app's 500 offline cap...
        nonce: 'nonce_p7_overlimit',
        timestamp: '2026-02-10T11:05:00.000Z',
        description: 'Raised the cap in a hacked client',
      }),
    );
    const limitPush = await post('/sync/push', {
      userId: alice.userId,
      publicKey: ALICE_PUBLIC_B64,
      transactions: [overLimit],
    });
    await check('the offline per-transaction cap is enforced server-side too', () => {
      const r = resultFor(limitPush.body, overLimit.transactionId);
      assert.equal(r.outcome, 'REJECTED');
      assert.equal(r.code, 'OVER_LIMIT'); // checked BEFORE the balance gate
    });

    const ghost = signedWith(
      MALLORY.privateKey,
      makeTx({
        id: 'TXN_p7_ghost',
        senderId: 'USER_ghost_phase7', // never registered
        receiverId: alice.userId,
        amount: 50,
        nonce: 'nonce_p7_ghost',
        timestamp: '2026-02-10T11:10:00.000Z',
        description: 'Valid signature, unknown sender',
        publicKey: rawPub(MALLORY),
      }),
    );
    const ghostPush = await post('/sync/push', {
      userId: alice.userId, // real pusher...
      publicKey: ALICE_PUBLIC_B64,
      transactions: [ghost], // ...uploading someone else's transaction
    });
    await check('an unregistered SENDER cannot be debited, valid signature or not', () => {
      const r = resultFor(ghostPush.body, ghost.transactionId);
      assert.equal(r.outcome, 'REJECTED');
      assert.equal(r.code, 'SENDER_NOT_REGISTERED');
    });

    // =====================================================================
    // D. Trust-on-first-use ONBOARDING + escrow landing.
    // =====================================================================
    const CAROL_USER = 'USER_carol_phase7';
    const DAVE_USER = 'USER_dave_phase7';

    const carolToDave = signedWith(
      CAROL.privateKey,
      makeTx({
        id: 'TXN_p7_carol_1',
        senderId: CAROL_USER,
        receiverId: DAVE_USER,
        amount: 150,
        nonce: 'nonce_p7_carol_1',
        timestamp: '2026-02-10T12:00:00.000Z',
        description: 'Carol paid Dave before Dave ever synced',
        publicKey: rawPub(CAROL),
      }),
    );
    const carolPush = await post('/sync/push', {
      userId: CAROL_USER,
      publicKey: rawPub(CAROL),
      transactions: [carolToDave],
    });
    await check('first push from an unknown userId ONBOARDS the account (created)', () => {
      assert.equal(carolPush.status, 200);
      assert.equal(carolPush.body.data.registration, 'created');
      assert.equal(resultFor(carolPush.body, carolToDave.transactionId).outcome, 'CONFIRMED');
    });
    await check('onboarding grant is SERVER-decided: 500 - 150 spent = 350', () => {
      assert.equal(carolPush.body.data.balance, 350);
    });

    const daveToCarol = signedWith(
      DAVE.privateKey,
      makeTx({
        id: 'TXN_p7_dave_1',
        senderId: DAVE_USER,
        receiverId: CAROL_USER,
        amount: 50,
        nonce: 'nonce_p7_dave_1',
        timestamp: '2026-02-10T12:05:00.000Z',
        description: 'Dave pays Carol back',
        publicKey: rawPub(DAVE),
      }),
    );
    const davePush = await post('/sync/push', {
      userId: DAVE_USER,
      publicKey: rawPub(DAVE),
      transactions: [daveToCarol],
    });
    await check('Dave onboards too - his 150 escrowed payment lands with the grant', () => {
      assert.equal(davePush.body.data.registration, 'created');
      assert.equal(resultFor(davePush.body, daveToCarol.transactionId).outcome, 'CONFIRMED');
      // 500 grant + 150 escrowed from Carol - 50 sent back = 600.
      assert.equal(davePush.body.data.balance, 600);
    });
    await check('Carol (already existing) is credited directly: 350 + 50 = 400', async () => {
      assert.equal(await balanceOf(CAROL_USER), 400);
    });

    const carolBatch = [400, 200].map((amount, i) =>
      signedWith(
        CAROL.privateKey,
        makeTx({
          id: `TXN_p7_carol_2_${i}`,
          senderId: CAROL_USER,
          receiverId: 'USER_someone_else',
          amount,
          nonce: `nonce_p7_carol_2_${i}`,
          timestamp: `2026-02-10T12:1${i}:00.000Z`,
          description: `Onboarded over-spend ${i}`,
          publicKey: rawPub(CAROL),
        }),
      ),
    );
    const carolBatchPush = await post('/sync/push', {
      userId: CAROL_USER,
      publicKey: rawPub(CAROL),
      transactions: carolBatch,
    });
    await check('onboarded accounts are arbitrated exactly like REST users', () => {
      assert.deepEqual(
        carolBatch.map((tx) => resultFor(carolBatchPush.body, tx.transactionId).outcome),
        ['CONFIRMED', 'REJECTED'],
      );
      // 400 left, first spend takes all of it, second cannot follow.
      assert.equal(carolBatchPush.body.data.balance, 0);
    });

    // =====================================================================
    // E. Pull reflects the authoritative ledger - and no server-side seed
    //    row was invented (the device already has its local one).
    // =====================================================================
    const pullDave = await post('/sync/pull', { userId: DAVE_USER });
    await check("Dave pulls both of his confirmed payments (his, and Carol's to him)", () => {
      const ids = pullDave.body.data.transactions
        .map((t) => t.transactionId)
        .filter((id) => id.startsWith('TXN_p7'))
        .sort();
      assert.deepEqual(ids, ['TXN_p7_carol_1', 'TXN_p7_dave_1']);
      assert.ok(pullDave.body.data.transactions.every((t) => t.status === 'CONFIRMED'));
    });
    const pullCarol = await post('/sync/pull', { userId: CAROL_USER });
    await check('onboarding wrote NO welcome top-up (the device would double-count it)', () => {
      const tops = pullCarol.body.data.transactions.filter((t) => t.type === 'TOPUP');
      assert.equal(tops.length, 0);
    });

    if (failed) {
      console.error('\nPhase 7 arbitration: FAILED');
      process.exitCode = 1;
    } else {
      console.log('\nPhase 7 arbitration: all checks passed.');
    }
  } finally {
    server.close();
    await disconnectDB();
  }
}

main().catch((error) => {
  console.error('Phase 7 demo crashed:', error);
  process.exitCode = 1;
});
