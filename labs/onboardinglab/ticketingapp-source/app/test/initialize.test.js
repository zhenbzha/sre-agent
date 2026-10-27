'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { initialize, findRequest, migrateDemoPlants } = require('../initialize');

function fixture(initialRows = []) {
  const rows = structuredClone(initialRows);
  const clients = [];
  const options = {
    env: { POSTGRES_HOST: 'example.test', POSTGRES_DATABASE: 'lab', POSTGRES_USER: 'lab', AZURE_CLIENT_ID: 'lab' },
    getAccessToken: async () => ({ token: 'test', expiresOnTimestamp: Date.now() + 60000 }),
    createClient: () => {
      const client = Object.assign(new EventEmitter(), {
        queries: [], closed: false, destroyed: false,
        async connect() {},
        async query(sql, values) {
          this.queries.push({ sql, values });
          if (sql.startsWith('INSERT INTO')) {
            if (rows.some((row) => row[0] === values[0] && row[1] === values[1]
              && [values[2], values[4]].includes(row[2]) && row[3] === values[3])) return { rowCount: 0 };
            rows.push(values.slice(0, 4));
            return { rowCount: 1 };
          }
          if (sql.startsWith('UPDATE material_requests')) {
            let rowCount = 0;
            for (const row of rows) {
              const match = values.findIndex((value, index) => index % 2 === 0 && value === row[2]);
              if (match >= 0) { row[2] = values[match + 1]; rowCount++; }
            }
            return { rowCount };
          }
          if (sql.startsWith('SELECT request_id')) {
            return { rows: values[0] === '1' ? [{ request_id: '1', material: 'Steel plate', quantity: 20, plant: 'Lyon' }] : [] };
          }
          return { rows: [] };
        },
        async end() { this.closed = true; },
        connection: { stream: { destroy() { client.destroyed = true; } } },
      });
      clients.push(client);
      return client;
    },
  };
  return { options, rows, clients };
}

test('initializer creates only material_requests and repeated seed initialization inserts nothing', async () => {
  const f = fixture();
  assert.deepEqual(await initialize(f.options), { initialized: true, inserted: 3 });
  assert.deepEqual(await initialize(f.options), { initialized: true, inserted: 0 });
  assert.equal(f.rows.length, 3);
  assert.deepEqual(f.rows.map((row) => row[2]), ['Tampere', 'Helsinki', 'Turku']);
  assert.equal(f.clients.length, 2);
  for (const client of f.clients) {
    assert.equal(client.queries[0].sql, 'BEGIN');
    assert.match(client.queries[1].sql, /pg_advisory_xact_lock/);
    assert.match(client.queries[2].sql, /CREATE TABLE IF NOT EXISTS material_requests/);
    assert.match(client.queries[2].sql, /GENERATED ALWAYS AS IDENTITY/);
    assert.match(client.queries[3].sql, /SELECT \$1::varchar\(120\), \$2::integer, \$3::varchar\(80\), \$4::timestamptz/);
    assert.equal(client.queries.at(-1).sql, 'COMMIT');
    assert.equal(client.closed, true);
    assert.equal(client.destroyed, true);
  }
});

test('initializer recognizes legacy French seeds without duplicating or rewriting them', async () => {
  const legacy = [
    ['Steel plate', 20, 'Lyon', '2026-01-01T00:00:00Z'],
    ['Bearing assembly', 12, 'Nantes', '2026-01-01T00:00:00Z'],
    ['Conveyor belt', 4, 'Lille', '2026-01-01T00:00:00Z'],
  ];
  const f = fixture(legacy);
  assert.deepEqual(await initialize(f.options), { initialized: true, inserted: 0 });
  assert.deepEqual(f.rows, legacy);
  assert.deepEqual(await migrateDemoPlants(f.options), { migrated: true, updated: 3 });
  assert.deepEqual(await initialize(f.options), { initialized: true, inserted: 0 });
  assert.equal(f.rows.length, 3);
});

test('explicit plant migration changes only the approved labels and is idempotent', async () => {
  const original = ['Lyon', 'Nantes', 'Lille', 'Oulu', 'Helsinki'].map((plant, index) => [
    `Material ${index}`, index + 1, plant, '2026-10-25T21:21:40.889Z',
  ]);
  const f = fixture(original);
  assert.deepEqual(await migrateDemoPlants(f.options), { migrated: true, updated: 3 });
  assert.deepEqual(await migrateDemoPlants(f.options), { migrated: true, updated: 0 });
  assert.deepEqual(f.rows, original.map((row, index) => [
    row[0], row[1], ['Tampere', 'Helsinki', 'Turku', 'Oulu', 'Helsinki'][index], row[3],
  ]));
  for (const client of f.clients) {
    assert.equal(client.queries.length, 1);
    assert.match(client.queries[0].sql, /SET plant = CASE plant WHEN \$1 THEN \$2/);
    assert.doesNotMatch(client.queries[0].sql, /SET\s+(request_id|material|quantity|created_at)|DELETE|INSERT|TRUNCATE/i);
    assert.deepEqual(client.queries[0].values, ['Lyon', 'Tampere', 'Nantes', 'Helsinki', 'Lille', 'Turku']);
    assert.equal(client.closed, true);
    assert.equal(client.destroyed, true);
  }
});

test('migration errors are propagated and always close the connection', async () => {
  const f = fixture();
  const createClient = f.options.createClient;
  f.options.createClient = () => {
    const client = createClient();
    client.query = async () => { throw new Error('Migration failed'); };
    return client;
  };
  await assert.rejects(migrateDemoPlants(f.options), /Migration failed/);
  assert.equal(f.clients[0].closed, true);
  assert.equal(f.clients[0].destroyed, true);
});

test('operator verification reads the exact request using a bound ID and rejects missing rows', async () => {
  const f = fixture();
  assert.deepEqual(await findRequest(f.options, '1'), {
    request_id: '1', material: 'Steel plate', quantity: 20, plant: 'Lyon',
  });
  assert.deepEqual(f.clients[0].queries[0].values, ['1']);
  await assert.rejects(findRequest(f.options, '2'), /Request not found/);
  await assert.rejects(findRequest(f.options, '1; DROP TABLE material_requests'), /Invalid request number/);
  assert.equal(f.clients.length, 2);
});

test('initializer errors cannot commit partial seeds and always close the connection', async () => {
  const f = fixture();
  const createClient = f.options.createClient;
  f.options.createClient = () => {
    const client = createClient();
    const query = client.query.bind(client);
    client.query = async (sql, values) => {
      if (sql.startsWith('INSERT')) throw new Error('Synthetic failure');
      return query(sql, values);
    };
    return client;
  };
  await assert.rejects(initialize(f.options), /Synthetic failure/);
  assert.equal(f.clients[0].queries.some(({ sql }) => sql === 'COMMIT'), false);
  assert.equal(f.clients[0].closed, true);
  assert.equal(f.clients[0].destroyed, true);
});
