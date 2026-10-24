'use strict';

const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { performance } = require('node:perf_hooks');
const { withDatabase } = require('./database');

const MAX_DB_ATTEMPTS = 4;
const MAX_BODY_BYTES = 2048;
const INSERT_REQUEST = 'INSERT INTO material_requests (material, quantity, plant) VALUES ($1, $2, $3) RETURNING request_id';
const LIST_LIMIT = 100;
const LIST_REQUESTS = 'SELECT request_id, material, quantity, plant, created_at FROM material_requests ORDER BY request_id DESC LIMIT $1';
class InputError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}
const assets = new Map([
  ['/', ['index.html', 'text/html; charset=utf-8']],
  ['/app.js', ['app.js', 'text/javascript; charset=utf-8']],
  ['/styles.css', ['styles.css', 'text/css; charset=utf-8']],
].map(([path, [file, type]]) => [path, {
  body: readFileSync(join(__dirname, 'public', file)), type,
}]));

function readInput(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    const timer = setTimeout(() => finish(408, 'Request body timed out.'), 5000);
    function finish(status, message, value) {
      clearTimeout(timer);
      request.removeListener('data', onData);
      request.removeListener('end', onEnd);
      request.removeListener('error', onError);
      request.removeListener('aborted', onError);
      if (status) {
        request.resume();
        reject(new InputError(status, message));
      } else {
        resolve(value);
      }
    }
    function onData(chunk) {
      const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      size += bytes.length;
      if (size > MAX_BODY_BYTES) return finish(413, 'Request body is too large.');
      chunks.push(bytes);
    }
    function onError() { finish(400, 'Request body could not be read.'); }
    function onEnd() {
      let value;
      try {
        const body = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(Buffer.concat(chunks));
        value = JSON.parse(body);
      } catch { return finish(400, 'Send a valid UTF-8 JSON material request.'); }
      if (!value || typeof value !== 'object' || Array.isArray(value) ||
          Object.keys(value).some((key) => !['material', 'quantity', 'plant'].includes(key)) ||
          typeof value.material !== 'string' || !value.material.trim() || value.material.trim().length > 120 ||
          typeof value.plant !== 'string' || !value.plant.trim() || value.plant.trim().length > 80 ||
          !value.material.isWellFormed() || !value.plant.isWellFormed() ||
          /[\u0000-\u001f\u007f]/.test(value.material + value.plant) ||
          !Number.isInteger(value.quantity) || value.quantity < 1 || value.quantity > 1000000) {
        return finish(400, 'Provide material (1-120 characters), quantity (1-1000000 whole units) and plant (1-80 characters).');
      }
      finish(0, '', { material: value.material.trim(), quantity: value.quantity, plant: value.plant.trim() });
    }
    request.on('data', onData);
    request.on('end', onEnd);
    request.on('error', onError);
    request.on('aborted', onError);
  });
}

function json(response, status, body) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify(body));
}

// Production supplies pg.Client, managed-identity token acquisition and telemetry.
function createHandler({ createClient, getAccessToken, telemetry, env = process.env }) {
  let activeAttempts = 0;

  function track(method, data) {
    try {
      telemetry?.[method](data);
    } catch {
      // Telemetry availability must never affect checkout or reveal SDK errors.
    }
  }

  async function listRequests(response) {
    const started = performance.now();
    const workload = env.WORKLOAD_OPTION || 'app-service-postgresql';
    let rows;
    let outcome = 'busy';
    if (workload === 'app-service-postgresql' && activeAttempts < MAX_DB_ATTEMPTS) {
      activeAttempts += 1;
      outcome = 'unavailable';
      try {
        const result = await withDatabase({
          createClient, getAccessToken, env, onTimeout: () => { outcome = 'timeout'; },
        }, (client) => client.query(LIST_REQUESTS, [LIST_LIMIT + 1]));
        if (!Array.isArray(result.rows)) throw new Error('Unexpected database result');
        rows = result.rows;
        outcome = 'listed';
      } catch {
        // Return a sanitized failure; database errors can contain credentials.
      } finally {
        activeAttempts -= 1;
        track('trackDependency', {
          name: 'PostgreSQL request listing',
          target: 'PostgreSQL',
          dependencyTypeName: 'PostgreSQL',
          data: LIST_REQUESTS,
          duration: performance.now() - started,
          success: rows !== undefined,
          resultCode: rows !== undefined ? '0' : '1',
          properties: { simulated: 'true', outcome },
        });
      }
    } else if (workload !== 'app-service-postgresql') {
      outcome = workload === 'app-service' ? 'database-free' : 'configuration-unavailable';
    }
    const status = rows !== undefined ? 200 : workload === 'app-service' ? 501 : 503;
    track('trackRequest', {
      name: 'GET /material-requests', url: 'http://localhost/material-requests',
      duration: performance.now() - started, resultCode: String(status), success: status === 200,
      properties: { simulated: 'true', outcome, 'http.method': 'GET' },
    });
    if (rows !== undefined) {
      return json(response, 200, {
        success: true, requests: rows.slice(0, LIST_LIMIT),
        limit: LIST_LIMIT, hasMore: rows.length > LIST_LIMIT,
      });
    }
    if (status === 503) response.setHeader('Retry-After', '3');
    return json(response, status, {
      success: false,
      message: status === 501
        ? 'Saved requests are not available in the database-free workload.'
        : 'Saved requests could not be loaded. Try refreshing the list.',
    });
  }

  return async function handler(request, response) {
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    response.setHeader('Referrer-Policy', 'no-referrer');
    response.setHeader('Content-Security-Policy',
      "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'none'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'");

    // Compare raw paths, without URL normalization or filesystem interpolation.
    const path = (request.url || '').split('?')[0];
    const asset = assets.get(path);
    const allowedMethod = path === '/checkout' ? 'POST' : 'GET';
    if (!asset && path !== '/healthz' && path !== '/checkout' && path !== '/material-requests') {
      request.resume();
      return json(response, 404, { error: 'Not found' });
    }
    if (request.method !== allowedMethod) {
      request.resume();
      response.setHeader('Allow', allowedMethod);
      return json(response, 405, { error: 'Method not allowed' });
    }
    if (path === '/healthz') {
      request.resume();
      return json(response, 200, { status: 'healthy' });
    }
    if (asset) {
      request.resume();
      response.writeHead(200, { 'Content-Type': asset.type });
      return response.end(asset.body);
    }
    if (path === '/material-requests') {
      request.resume();
      return listRequests(response);
    }

    const started = performance.now();
    let fields;
    try {
      if (request.headers['content-type']?.split(';')[0].trim().toLowerCase() !== 'application/json') {
        request.resume();
        throw new InputError(415, 'Send a material request with Content-Type: application/json.');
      }
      fields = await readInput(request);
    } catch (error) {
      if (!(error instanceof InputError)) throw error;
      track('trackRequest', {
        name: 'POST /checkout', url: 'http://localhost/checkout',
        duration: performance.now() - started, resultCode: String(error.status), success: false,
        properties: { simulated: 'true', outcome: 'invalid-input', 'http.method': 'POST' },
      });
      return json(response, error.status, { success: false, simulated: true, message: error.message });
    }
    let success = false;
    let requestId;
    let outcome = 'busy';
    const workloadOption = env.WORKLOAD_OPTION || 'app-service-postgresql';
    if (workloadOption === 'app-service') {
      success = env.APP_FAULT_ENABLED !== 'true';
      outcome = success ? 'available' : 'application-fault';
    } else if (workloadOption === 'app-service-postgresql' && activeAttempts < MAX_DB_ATTEMPTS) {
      activeAttempts += 1;
      const dependencyStarted = performance.now();
      outcome = 'unavailable';
      try {
        const result = await withDatabase({
          createClient, getAccessToken, env, onTimeout: () => { outcome = 'timeout'; },
        }, (client) => client.query(INSERT_REQUEST, [fields.material, fields.quantity, fields.plant]));
        requestId = result.rows[0]?.request_id;
        if (typeof requestId !== 'string' || !/^[1-9][0-9]*$/.test(requestId)) {
          throw new Error('Database did not return a request number');
        }
        success = true;
        outcome = 'saved';
      } catch {
        // Never serialize or log pg errors, connection settings, or credentials.
      } finally {
        activeAttempts -= 1;
      }
      track('trackDependency', {
        name: 'PostgreSQL connectivity',
        target: 'PostgreSQL',
        dependencyTypeName: 'PostgreSQL',
        data: INSERT_REQUEST,
        duration: performance.now() - dependencyStarted,
        success,
        resultCode: success ? '0' : '1',
        properties: { simulated: 'true', outcome },
      });
    } else if (workloadOption !== 'app-service-postgresql') {
      outcome = 'configuration-unavailable';
    }

    const status = success ? 200 : 503;
    track('trackRequest', {
      name: 'POST /checkout',
      url: 'http://localhost/checkout', // Never trust Host/query parameters in telemetry.
      duration: performance.now() - started,
      resultCode: String(status),
      success,
      // AI 3.16.0 omits http.method for named requests; the exporter needs it for HTTP status mapping.
      properties: { simulated: 'true', outcome, 'http.method': 'POST' },
    });
    if (success) {
      return json(response, status, {
        success: true, simulated: true,
        ...(requestId ? { requestId } : {}),
        message: workloadOption === 'app-service'
          ? 'Material request simulated; not saved (database-free workload).'
          : 'Request saved',
      });
    }
    response.setHeader('Retry-After', '3');
    return json(response, status, {
      success: false, simulated: true,
      message: 'Material request could not be confirmed. The service may be busy or the database unavailable. Check the outcome before retrying.',
    });
  };
}

module.exports = { createHandler };