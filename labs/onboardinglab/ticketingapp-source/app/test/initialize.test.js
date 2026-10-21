'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { initialize, findRequest } = require('../initialize');

function fixture() {
  const rows = [];
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
            if (rows.some((row) => JSON.stringify(row) === JSON.stringify(values))) return { rowCount: 0 };
            rows.push(values);
            return { rowCount: 1 };
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
