'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { runInNewContext } = require('node:vm');

function browser(success = true, fetchCheckout) {
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
      if (url === '/checkout' && fetchCheckout) return fetchCheckout(options);
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

function submit(fixture) {
  let prevented = false;
  const pending = fixture.elements['request-form'].submit({
    preventDefault() { prevented = true; },
  });
  assert.equal(prevented, true);
  return pending;
}

test('UI submits material payload and displays the exact generated ID without numeric rounding', async () => {
  const f = browser();
  assert.deepEqual(f.calls.map(({ url }) => url), ['/healthz']);
  await submit(f);
  const submitted = f.calls.find(({ url }) => url === '/checkout');
  assert.deepEqual(JSON.parse(submitted.options.body), { material: 'Steel plate', quantity: 20, plant: 'Lyon' });
  assert.equal(submitted.options.headers['Content-Type'], 'application/json');
  assert.equal(f.elements.result.textContent, 'Request saved #9007199254740993');
  assert.equal(f.elements.successes.textContent, 1);
  assert.equal(f.elements.health.textContent, 'Application is running');
  assert.equal(f.elements['receipt-detail'].textContent, 'Steel plate · 20 units · Lyon');
  assert.equal(f.elements.checkout.textContent, 'Submit request');
});

test('UI shows a clear server failure and does not count it as saved', async () => {
  const f = browser(false);
  await submit(f);
  assert.equal(f.elements.result.textContent, 'Database unavailable.');
  assert.equal(f.elements.failures.textContent, 1);
  assert.equal(f.elements.successes.textContent, 0);
});

test('form validation prevents a submission and leaves the inputs available', async () => {
  const f = browser();
  f.elements.quantity.reportValidity = () => false;
  await submit(f);
  assert.equal(f.calls.filter(({ url }) => url === '/checkout').length, 0);
  assert.equal(f.elements.material.disabled, false);
});

test('pending submission locks the form, preserves its details, and prevents duplicate requests', async () => {
  let finish;
  const f = browser(true, () => new Promise((resolve) => { finish = resolve; }));
  const pending = submit(f);
  assert.equal(f.elements.checkout.disabled, true);
  assert.equal(f.elements.checkout.textContent, 'Submitting…');
  assert.equal(f.elements.start.disabled, true);
  assert.equal(f.elements.material.disabled, true);
  await submit(f);
  assert.equal(f.calls.filter(({ url }) => url === '/checkout').length, 1);
  finish({ ok: true, json: async () => ({ success: true, requestId: '42' }) });
  await pending;
  assert.equal(f.elements.result.textContent, 'Request saved #42');
  assert.equal(f.elements.checkout.disabled, false);
  assert.equal(f.elements.material.disabled, false);
});

test('transport failure is explicit and does not claim a request was saved', async () => {
  const f = browser(true, async () => { throw new Error('Connection interrupted'); });
  await submit(f);
  assert.match(f.elements.result.textContent, /could not be confirmed.*before retrying/);
  assert.equal(f.elements.result.dataset.state, 'failure');
  assert.equal(f.elements.failures.textContent, 1);
  assert.equal(f.elements.checkout.disabled, false);
});

test('database-free simulation shows its actual message without inventing a request number', async () => {
  const f = browser(true, async () => ({
    ok: true,
    json: async () => ({ success: true, message: 'Simulated success; no database record was saved.' }),
  }));
  await submit(f);
  assert.equal(f.elements.result.textContent, 'Simulated success; no database record was saved.');
  assert.equal(f.elements.successes.textContent, 1);
});

test('simulation remains bounded and stops on navigation without starting on load', async () => {
  const f = browser();
  assert.equal(f.timers.size, 0);
  f.elements.start.click();
  assert.ok([...f.timers.values()].includes(10 * 60 * 1000));
  assert.equal(f.elements.stop.disabled, false);
  assert.equal(f.elements.loop.textContent, 'Running');
  f.events.pagehide();
  await new Promise(setImmediate);
  assert.equal(f.timers.size, 0);
  assert.equal(f.elements.stop.disabled, true);
  assert.equal(f.elements.loop.textContent, 'Stopped');
  assert.equal(f.elements.loop.dataset.state, 'idle');
  assert.equal(f.calls.filter(({ url }) => url === '/checkout').length, 1);
});

test('simulation deadline stops the loop and restores the form', async () => {
  const f = browser();
  f.elements.start.click();
  await new Promise(setImmediate);
  const deadline = [...f.timers].find(([, delay]) => delay === 10 * 60 * 1000)[0];
  deadline();
  assert.equal(f.elements.loop.textContent, 'Finished after 10 minutes');
  assert.equal(f.elements.stop.disabled, true);
  assert.equal(f.elements.checkout.disabled, false);
  assert.equal(f.timers.size, 0);
});

test('page has material fields and no external imagery or ticketing copy', () => {
  const html = readFileSync(join(__dirname, '../public/index.html'), 'utf8');
  const css = readFileSync(join(__dirname, '../public/styles.css'), 'utf8');
  assert.match(html, /SCM Material Requests/);
  assert.match(html, /Submit request/);
  for (const id of ['material', 'quantity', 'plant']) assert.ok(html.includes(`id="${id}"`));
  assert.doesNotMatch(html, /Reserve tickets|Lumen|concert|seats/i);
  assert.doesNotMatch(css, /https?:|url\(/);
  assert.match(html, /<form id="request-form"/);
  assert.match(html, /id="checkout" type="submit"/);
  assert.match(html, /<details class="demo-controls">/);
  const controls = html.slice(html.indexOf('<details'), html.indexOf('</details>'));
  for (const id of ['start', 'stop', 'loop', 'attempts', 'successes', 'failures', 'health', 'timing']) {
    assert.ok(controls.includes(`id="${id}"`), `${id} belongs in the collapsed demo controls`);
  }
  assert.doesNotMatch(html, /event-hero|event-meta|YOUR MATERIALS|LAB CONTROLS/);
  assert.doesNotMatch(css, /gradient|Georgia|Trebuchet/);
});
