'use strict';

const DB_TIMEOUT_MS = 5000;

function databaseConfig(env, getAccessToken) {
  const port = Number(env.POSTGRES_PORT || 5432);
  if (!env.POSTGRES_HOST || !env.POSTGRES_DATABASE || !env.POSTGRES_USER ||
      !env.AZURE_CLIENT_ID || typeof getAccessToken !== 'function' ||
      !Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error('Database configuration unavailable');
  }
  return {
    host: env.POSTGRES_HOST,
    port,
    database: env.POSTGRES_DATABASE,
    user: env.POSTGRES_USER,
    password: async () => {
      const accessToken = await getAccessToken('https://ossrdbms-aad.database.windows.net/.default');
      if (!accessToken || typeof accessToken.token !== 'string' || !accessToken.token ||
          !Number.isFinite(accessToken.expiresOnTimestamp) || accessToken.expiresOnTimestamp <= Date.now()) {
        throw new Error('Database credential unavailable');
      }
      return accessToken.token;
    },
    ssl: { rejectUnauthorized: true },
    connectionTimeoutMillis: DB_TIMEOUT_MS,
    query_timeout: DB_TIMEOUT_MS,
    statement_timeout: DB_TIMEOUT_MS,
  };
}

async function withDatabase({ createClient, getAccessToken, env, onTimeout }, operation) {
  let client;
  let timer;
  let expired = false;
  try {
    client = createClient(databaseConfig(env, getAccessToken));
    const connectionError = new Promise((_, reject) => client.on('error', reject));
    const deadline = new Promise((_, reject) => {
      timer = setTimeout(() => {
        expired = true;
        onTimeout?.();
        reject(new Error('Database deadline exceeded'));
      }, DB_TIMEOUT_MS);
    });
    return await Promise.race([
      (async () => {
        await client.connect();
        if (expired) throw new Error('Database deadline exceeded');
        return operation(client);
      })(),
      connectionError,
      deadline,
    ]);
  } finally {
    clearTimeout(timer);
    if (client) {
      try {
        await client.end();
      } catch {
        // Force-close below even if graceful shutdown failed.
      } finally {
        // pg has no public force-close method; never retain a timed-out socket.
        client.connection.stream.destroy();
      }
    }
  }
}

module.exports = { withDatabase };
