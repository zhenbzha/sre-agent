'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { runInNewContext } = require('node:vm');

function browser(success = true) {
  const elements = {};
  const calls = [];
  const timers = new Map();
  const events = {};
  runInNewContext(readFileSync(join(__dirname, '../public/app.js'), 'utf8'), {
    document: { getElementById(id) {
      elements[id] = {
        value: ({ material: 'Steel plate', quantity: '20', plant: 'Lyon' })[id],
        dataset: {}, disabled: false, reportValidity: () => true,
        addEventListener(event, callback) { this[event] = callback; },
      };
      return elements[id];
    } },
    window: { addEventListener(event, callback) { events[event] = callback; } },
    fetch: async (url, options) => {
      calls.push({ url, options });
      return { ok: url === '/healthz' || success, json: async () => success
        ? { success: true, requestId: '9007199254740993', message: 'Request saved' }
        : { success: false, message: 'Database unavailable.' } };
    },
    AbortSignal, AbortController, performance, Date,
    setTimeout(callback, delay) { timers.set(callback, delay); return callback; },
    clearTimeout(timer) { timers.delete(timer); },
  });
  return { elements, calls, timers, events };
}

test('UI submits material payload and displays the exact generated ID without numeric rounding', async () => {
  const f = browser();
  assert.deepEqual(f.calls.map(({ url }) => url), ['/healthz']);
  await f.elements.checkout.click();
  const submitted = f.calls.find(({ url }) => url === '/checkout');
  assert.deepEqual(JSON.parse(submitted.options.body), { material: 'Steel plate', quantity: 20, plant: 'Lyon' });
  assert.equal(submitted.options.headers['Content-Type'], 'application/json');
  assert.equal(f.elements.result.textContent, 'Request saved #9007199254740993');
  assert.equal(f.elements.successes.textContent, 1);
  assert.equal(f.elements.health.textContent, 'Application is running');
});

test('UI shows a clear server failure and does not count it as saved', async () => {
  const f = browser(false);
  await f.elements.checkout.click();
  assert.equal(f.elements.result.textContent, 'Database unavailable.');
  assert.equal(f.elements.failures.textContent, 1);
  assert.equal(f.elements.successes.textContent, 0);
});

test('simulation remains bounded and stops on navigation without starting on load', async () => {
  const f = browser();
  assert.equal(f.timers.size, 0);
  f.elements.start.click();
  assert.ok([...f.timers.values()].includes(10 * 60 * 1000));
  assert.equal(f.elements.stop.disabled, false);
  f.events.pagehide();
  await new Promise(setImmediate);
  assert.equal(f.timers.size, 0);
  assert.equal(f.elements.stop.disabled, true);
  assert.equal(f.calls.filter(({ url }) => url === '/checkout').length, 1);
});

test('page has material fields and no external imagery or ticketing copy', () => {
  const html = readFileSync(join(__dirname, '../public/index.html'), 'utf8');
  const css = readFileSync(join(__dirname, '../public/styles.css'), 'utf8');
  assert.match(html, /SCM Material Requests/);
  assert.match(html, /Submit request/);
  for (const id of ['material', 'quantity', 'plant']) assert.ok(html.includes(`id="${id}"`));
  assert.doesNotMatch(html, /Reserve tickets|Lumen|concert|seats/i);
  assert.doesNotMatch(css, /https?:|url\(/);
});
