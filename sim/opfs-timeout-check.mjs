import assert from 'node:assert/strict';
import {
  createOpfsBridgeFactory,
  closeSimStorage,
  getSimDb,
  getSimPool,
} from './store-bridge.js';

async function testLateArrivingOpfsIsCleanedUp() {
  closeSimStorage();

  let resolveLatePool;
  const latePoolPromise = new Promise((resolve) => {
    resolveLatePool = resolve;
  });

  let poolClosed = false;
  let dbClosed = false;
  let execCalled = false;

  const fakePool = {
    closed: false,
    close() {
      this.closed = true;
      poolClosed = true;
    },
    OpfsSAHPoolDb: class {
      constructor() {
        this.closed = false;
      }
      exec() {
        execCalled = true;
      }
      close() {
        this.closed = true;
        dbClosed = true;
      }
    },
  };

  const fakeSqliteModule = {
    installOpfsSAHPoolVfs: async () => {
      await latePoolPromise;
      return fakePool;
    },
  };

  const storageEvents = [];
  const factory = await createOpfsBridgeFactory({
    timeoutMs: 50,
    importSqlite: async () => fakeSqliteModule,
    onStorage: (ev) => storageEvents.push(ev),
  });

  // 1. Timeout should have triggered fallback to Map bridge
  assert.equal(typeof factory, 'function', 'Factory must be returned');
  const bridge = factory('test-node');
  assert.equal(typeof bridge.put, 'function', 'Map bridge must have put method');
  assert.equal(storageEvents.length, 1, 'Storage event must be emitted');
  assert.equal(storageEvents[0].backend, 'memory', 'Backend must report memory');
  assert.equal(getSimDb(), null, 'simDb must be null after timeout');

  // 2. Now simulate late arrival of OPFS pool
  resolveLatePool();
  await new Promise((r) => setTimeout(r, 20));

  // Invariant (PLAT-012): late setup must never retain DB or strand the pool lock
  assert.equal(getSimDb(), null, 'simDb must remain null after late resolution');
  assert.equal(getSimPool(), null, 'simPool must remain null after late resolution');
  assert.equal(poolClosed, true, 'late-arriving pool must be closed immediately upon arrival');
  assert.equal(execCalled, false, 'late setup must not mutate tables or execute PRAGMAs');

  console.log('  ok testLateArrivingOpfsIsCleanedUp');
}

async function testSuccessfulOpfsBeforeTimeout() {
  closeSimStorage();

  let poolClosed = false;
  let dbClosed = false;

  const fakePool = {
    close() {
      poolClosed = true;
    },
    OpfsSAHPoolDb: class {
      exec() {}
      close() {
        dbClosed = true;
      }
    },
  };

  const fakeSqliteModule = {
    installOpfsSAHPoolVfs: async () => fakePool,
  };

  const storageEvents = [];
  const factory = await createOpfsBridgeFactory({
    timeoutMs: 500,
    importSqlite: async () => fakeSqliteModule,
    onStorage: (ev) => storageEvents.push(ev),
  });

  assert.equal(storageEvents[0].backend, 'opfs-sqlite', 'Backend must report opfs-sqlite');
  assert.notEqual(getSimDb(), null, 'simDb must be populated on success');
  assert.notEqual(getSimPool(), null, 'simPool must be populated on success');

  closeSimStorage();
  assert.equal(poolClosed, true, 'closeSimStorage must close active pool');
  assert.equal(dbClosed, true, 'closeSimStorage must close active db');
  assert.equal(getSimDb(), null, 'simDb must be cleared');
  assert.equal(getSimPool(), null, 'simPool must be cleared');

  console.log('  ok testSuccessfulOpfsBeforeTimeout');
}

async function run() {
  console.log('Running OPFS initialization timeout regression test (PLAT-012)...');
  await testLateArrivingOpfsIsCleanedUp();
  await testSuccessfulOpfsBeforeTimeout();
  console.log('All OPFS timeout checks passed.');
}

run().catch((err) => {
  console.error(err);
  process.exit(1);
});
