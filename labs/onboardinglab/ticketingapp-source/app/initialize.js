'use strict';

const { withDatabase } = require('./database');

const SEEDS = [
  ['Steel plate', 20, 'Lyon', '2026-01-01T00:00:00Z'],
  ['Bearing assembly', 12, 'Nantes', '2026-01-01T00:00:00Z'],
  ['Conveyor belt', 4, 'Lille', '2026-01-01T00:00:00Z'],
];

async function initialize(options) {
  return withDatabase(options, async (client) => {
    await client.query('BEGIN');
    // Serialize concurrent initializers before DDL; rollback also releases the lock.
    await client.query('SELECT pg_advisory_xact_lock(74321001)');
    await client.query(`CREATE TABLE IF NOT EXISTS material_requests (
      request_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      material varchar(120) NOT NULL CHECK (length(btrim(material)) > 0),
      quantity integer NOT NULL CHECK (quantity BETWEEN 1 AND 1000000),
      plant varchar(80) NOT NULL CHECK (length(btrim(plant)) > 0),
      created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
    )`);
    let inserted = 0;
    for (const seed of SEEDS) {
      const result = await client.query(
        `INSERT INTO material_requests (material, quantity, plant, created_at)
         SELECT $1::varchar(120), $2::integer, $3::varchar(80), $4::timestamptz
         WHERE NOT EXISTS (
           SELECT 1 FROM material_requests
           WHERE material = $1 AND quantity = $2 AND plant = $3 AND created_at = $4::timestamptz
         ) RETURNING request_id`, seed);
      inserted += result.rowCount;
    }
    await client.query('COMMIT');
    return { initialized: true, inserted };
  });
}

async function findRequest(options, requestId) {
  if (!/^[1-9][0-9]{0,18}$/.test(requestId)) throw new Error('Invalid request number');
  return withDatabase(options, async (client) => {
    const result = await client.query(
      'SELECT request_id, material, quantity, plant, created_at FROM material_requests WHERE request_id = $1',
      [requestId]);
    if (result.rows.length !== 1) throw new Error('Request not found');
    return result.rows[0];
  });
}

if (require.main === module) {
  const args = process.argv.slice(2);
  if (args.length !== 0 && !(args.length === 2 && args[0] === '--request')) {
    console.error('Usage: node initialize.js [--request REQUEST_ID]');
    process.exitCode = 1;
  } else {
    const { Client } = require('pg');
    const { ManagedIdentityCredential } = require('@azure/identity');
    const credential = new ManagedIdentityCredential({ clientId: process.env.AZURE_CLIENT_ID });
    const options = {
      env: process.env,
      createClient: (config) => new Client(config),
      getAccessToken: (scope) => credential.getToken(scope),
    };
    const operation = args.length ? findRequest(options, args[1]) : initialize(options);
    operation.then((result) => console.info(JSON.stringify(result))).catch(() => {
      console.error('Material-request database operation failed. Check configuration, identity, private connectivity and schema; no credentials are logged.');
      process.exitCode = 1;
    });
  }
}

module.exports = { initialize, findRequest };
