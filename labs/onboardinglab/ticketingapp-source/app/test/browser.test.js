'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { runInNewContext } = require('node:vm');

function browser(success = true, fetchCheckout, fetchList) {
  const elements = {};
  const calls = [];
  const timers = new Map();
  const events = {};
  function element(tag = 'div') {
    return {
      tagName: tag.toUpperCase(), children: [], dataset: {}, disabled: false, hidden: false,
      value: '', textContent: '', reportValidity: () => true,
      addEventListener(event, callback) { this[event] = callback; },
      setAttribute(name, value) { this[name] = value; },
      append(...children) { this.children.push(...children); },
      replaceChildren(...children) { this.children = children; },
      showModal() { this.open = true; },
      close() { this.open = false; },
      focus() {},
    };
  }
  runInNewContext(readFileSync(join(__dirname, '../public/app.js'), 'utf8'), {
    document: { createElement: element, getElementById(id) {
      elements[id] = element();
      elements[id].value = ({ material: 'Steel plate', quantity: '20', plant: 'Lyon', sort: 'newest' })[id] || '';
      return elements[id];
    } },
    window: { addEventListener(event, callback) { events[event] = callback; } },
    fetch: async (url, options) => {
      calls.push({ url, options });
      if (url === '/material-requests') return fetchList ? fetchList() : {
        ok: true, json: async () => ({ success: true, requests: [], limit: 100, hasMore: false }),
      };
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
  assert.deepEqual(f.calls.map(({ url }) => url), ['/healthz', '/material-requests']);
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
  f.elements['new-request'].click();
  const pending = submit(f);
  assert.equal(f.elements.checkout.disabled, true);
  assert.equal(f.elements.checkout.textContent, 'Submitting...');
  assert.equal(f.elements.start.disabled, true);
  assert.equal(f.elements.material.disabled, true);
  let cancelled = false;
  f.elements['request-dialog'].cancel({ preventDefault() { cancelled = true; } });
  assert.equal(cancelled, true, 'Escape cannot hide a submission with an uncertain write outcome');
  f.elements['cancel-request'].click();
  assert.equal(f.elements['request-dialog'].open, true);
  await submit(f);
  assert.equal(f.calls.filter(({ url }) => url === '/checkout').length, 1);
  finish({ ok: true, json: async () => ({ success: true, requestId: '42' }) });
  await pending;
  assert.equal(f.elements.result.textContent, 'Request saved #42');
  assert.equal(f.elements.checkout.disabled, false);
  assert.equal(f.elements.material.disabled, false);
  assert.equal(f.elements['request-dialog'].open, false);
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

test('page is a Metso requests workspace with separate demo controls and an accessible request drawer', () => {
  const html = readFileSync(join(__dirname, '../public/index.html'), 'utf8');
  const css = readFileSync(join(__dirname, '../public/styles.css'), 'utf8');
  assert.match(html, /Metso \| Material requests/);
  assert.match(html, /Submit request/);
  for (const id of ['material', 'quantity', 'plant']) assert.ok(html.includes(`id="${id}"`));
  assert.doesNotMatch(html, /Reserve tickets|Lumen|concert|seats/i);
  assert.doesNotMatch(css, /https?:|url\(/);
  assert.match(html, /<form id="request-form"/);
  assert.match(html, /id="checkout" type="submit"/);
  assert.match(html, /<section id="demo-view"[^>]* hidden>/);
  assert.match(html, /<dialog id="request-dialog" aria-labelledby="dialog-title">/);
  assert.match(html, /<table>/);
  const controls = html.slice(html.indexOf('<section id="demo-view"'), html.indexOf('<noscript>'));
  for (const id of ['start', 'stop', 'loop', 'attempts', 'successes', 'failures', 'health', 'timing']) {
    assert.ok(controls.includes(`id="${id}"`), `${id} belongs in the separate demo controls`);
  }
  assert.doesNotMatch(html, /event-hero|event-meta|YOUR MATERIALS|LAB CONTROLS/);
  assert.doesNotMatch(css, /gradient|Georgia|Trebuchet/);
});

function listResponse(requests, hasMore = false) {
  return { ok: true, json: async () => ({ success: true, requests, limit: 100, hasMore }) };
}

function record(id, plant = 'Lyon', material = 'Wear plate') {
  return { request_id: String(id), plant, material, quantity: 4, created_at: '2026-10-22T10:00:00Z' };
}

test('request list displays real response fields, preserves bigint IDs and supports filtering and pagination', async () => {
  const data = Array.from({ length: 12 }, (_, i) => record(9007199254740993n + BigInt(i), i % 2 ? 'Lille' : 'Lyon'));
  const f = browser(true, undefined, async () => listResponse(data));
  await new Promise(setImmediate);
  assert.equal(f.elements['request-count'].textContent, '12');
  assert.equal(f.elements['request-rows'].children.length, 10);
  assert.equal(f.elements['request-rows'].children[0].children[0].textContent, '#9007199254741004');
  f.elements.next.click();
  assert.equal(f.elements['page-info'].textContent, '11-12 of 12 requests');
  assert.equal(f.elements['request-rows'].children.length, 2);
  f.elements['plant-filter'].value = 'Lyon';
  f.elements['plant-filter'].change();
  assert.equal(f.elements['page-info'].textContent, '1-6 of 6 requests');
  f.elements.search.value = '#9007199254740993';
  f.elements.search.input();
  assert.equal(f.elements['page-info'].textContent, '1-1 of 1 requests');
  assert.equal(f.elements['request-rows'].children[0].children[0].textContent, '#9007199254740993');
  f.elements.search.value = '';
  f.elements['plant-filter'].value = '';
  f.elements.sort.value = 'oldest';
  f.elements.sort.change();
  assert.equal(f.elements['request-rows'].children[0].children[0].textContent, '#9007199254740993');
});

test('list errors preserve previously loaded rows and disclose staleness', async () => {
  let reads = 0;
  const f = browser(true, undefined, async () => ++reads === 1 ? listResponse([record(42)]) : {
    ok: false, json: async () => ({ message: 'Saved requests could not be loaded.' }),
  });
  await new Promise(setImmediate);
  await f.elements.refresh.click();
  assert.equal(f.elements['request-rows'].children[0].children[0].textContent, '#42');
  assert.equal(f.elements['list-error'].hidden, false);
  assert.match(f.elements['list-error'].textContent, /Showing the last loaded requests/);
});

test('malformed list data is an explicit unavailable state, not a fabricated empty list', async () => {
  const f = browser(true, undefined, async () => listResponse([{ ...record(42), request_id: 42 }]));
  await new Promise(setImmediate);
  assert.equal(f.elements['request-count'].textContent, 'Unavailable');
  assert.match(f.elements['list-error'].textContent, /unexpected request list/);
  assert.equal(f.elements['list-error'].hidden, false);
});

test('request content is inserted as text and never interpreted as HTML', async () => {
  const material = '<img src=x onerror=alert(1)>';
  const f = browser(true, undefined, async () => listResponse([record(42, 'Lyon', material)]));
  await new Promise(setImmediate);
  const cell = f.elements['request-rows'].children[0].children[1];
  assert.equal(cell.textContent, material);
  assert.deepEqual(cell.children, []);
});

test('simulation configuration uses the request drawer without saving or generating traffic', async () => {
  const f = browser();
  f.elements['configure-simulation'].click();
  assert.equal(f.elements['request-dialog'].open, true);
  assert.equal(f.elements.checkout.textContent, 'Use these values');
  f.elements.material.value = 'Crusher liner';
  await submit(f);
  assert.equal(f.elements['request-dialog'].open, false);
  assert.equal(f.elements['sim-material'].textContent, 'Crusher liner');
  assert.equal(f.calls.filter(({ url }) => url === '/checkout').length, 0);
  f.elements['new-request'].click();
  assert.equal(f.elements.checkout.textContent, 'Submit request');
});

test('cancelled drawer edits do not silently change simulation values', () => {
  const f = browser();
  f.elements['configure-simulation'].click();
  f.elements.material.value = 'Unsaved edit';
  f.elements.quantity.value = '0';
  f.elements['cancel-request'].click();
  assert.equal(f.elements.material.value, 'Steel plate');
  assert.equal(Number(f.elements.quantity.value), 20);
  assert.equal(f.elements['sim-material'].textContent, 'Steel plate');
  assert.equal(f.elements['request-dialog'].open, false);
});

test('a saved request remains successful when the following list refresh fails', async () => {
  let reads = 0;
  const f = browser(true, undefined, async () => ++reads === 1 ? listResponse([]) : {
    ok: false, json: async () => ({ message: 'Saved requests could not be loaded.' }),
  });
  await new Promise(setImmediate);
  await submit(f);
  await new Promise(setImmediate);
  assert.equal(f.elements.result.textContent, 'Request saved #9007199254740993');
  assert.equal(f.elements.result.dataset.state, 'success');
  assert.equal(f.elements.successes.textContent, 1);
  assert.equal(f.elements.failures.textContent, 0);
  assert.equal(f.elements['list-error'].hidden, false);
});

test('a save during an existing list fetch queues a fresh read instead of retaining its stale snapshot', async () => {
  let finishFirst;
  let reads = 0;
  const f = browser(true, undefined, () => ++reads === 1
    ? new Promise((resolve) => { finishFirst = resolve; })
    : Promise.resolve(listResponse([record('9007199254740993')])));
  await submit(f);
  assert.equal(reads, 1);
  finishFirst(listResponse([]));
  await new Promise(setImmediate);
  assert.equal(reads, 2);
  assert.equal(f.elements['request-rows'].children[0].children[0].textContent, '#9007199254740993');
});

test('empty and filtered-empty lists are distinct, with the bounded search scope disclosed', async () => {
  const empty = browser(true, undefined, async () => listResponse([]));
  const limited = browser(true, undefined, async () => listResponse([record(42)], true));
  await new Promise(setImmediate);
  assert.equal(empty.elements['request-rows'].children[0].children[0].children[0].textContent, 'No requests yet');
  assert.match(limited.elements.coverage.textContent, /latest 100 saved requests/);
  limited.elements.search.value = 'Nothing matches this';
  limited.elements.search.input();
  assert.equal(limited.elements['request-rows'].children[0].children[0].children[0].textContent, 'No matching requests');
});

test('an invalid generated request number is not displayed as a confirmed save', async () => {
  const f = browser(true, async () => ({ ok: true, json: async () => ({ success: true, requestId: 42 }) }));
  await submit(f);
  assert.equal(f.elements.result.dataset.state, 'failure');
  assert.equal(f.elements.successes.textContent, 0);
  assert.match(f.elements.result.textContent, /could not be confirmed/);
});
