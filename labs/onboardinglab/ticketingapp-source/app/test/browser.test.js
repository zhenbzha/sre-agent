'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { runInNewContext } = require('node:vm');

function browser(success = true, fetchCheckout, fetchList, fetchHealth, fetchDelete) {
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
      focus() { elements.focused = this; },
    };
  }
  runInNewContext(readFileSync(join(__dirname, '../public/app.js'), 'utf8'), {
    document: { createElement: element, createElementNS(namespace, tag) { return element(tag); }, getElementById(id) {
      elements[id] = element();
      elements[id].value = ({ material: 'Steel plate', quantity: '20', plant: 'Tampere', sort: 'newest' })[id] || '';
      return elements[id];
    } },
    window: { addEventListener(event, callback) { events[event] = callback; } },
    fetch: async (url, options) => {
      calls.push({ url, options });
      if (url === '/material-requests') return fetchList ? fetchList(options) : {
        ok: true, json: async () => ({ success: true, requests: [], limit: 100, hasMore: false }),
      };
      if (url === '/checkout' && fetchCheckout) return fetchCheckout(options);
      if (url === '/healthz' && fetchHealth) return fetchHealth(options);
      if (options?.method === 'DELETE') {
        assert.ok(fetchDelete, 'Unexpected deletion');
        return fetchDelete(url, options);
      }
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
  assert.deepEqual(JSON.parse(submitted.options.body), { material: 'Steel plate', quantity: 20, plant: 'Tampere' });
  assert.equal(submitted.options.headers['Content-Type'], 'application/json');
  assert.equal(f.elements.result.textContent, 'Request saved #9007199254740993');
  assert.equal(f.elements.successes.textContent, 1);
  assert.equal(f.elements.health.textContent, 'Application is running');
  assert.equal(f.elements['receipt-detail'].textContent, 'Steel plate · 20 units · Tampere');
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

test('page is a Zava requests workspace with Finnish defaults and an accessible request drawer', () => {
  const html = readFileSync(join(__dirname, '../public/index.html'), 'utf8');
  const css = readFileSync(join(__dirname, '../public/styles.css'), 'utf8');
  assert.match(html, /Zava \| Material requests/);
  assert.match(html, /aria-label="Zava supply chain home">Zava</);
  assert.match(html, /id="sim-plant">Tampere</);
  assert.doesNotMatch(html, /Metso|Lyon|Nantes|Lille/);
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

test('the plant field is a native selector with all demo plants, not filtered autocomplete', () => {
  const html = readFileSync(join(__dirname, '../public/index.html'), 'utf8');
  const selector = html.match(/<select id="plant" name="plant" required>([\s\S]*?)<\/select>/);
  assert.ok(selector, 'Plant must use a labeled native select');
  assert.deepEqual([...selector[1].matchAll(/<option value="([^"]+)"/g)].map((match) => match[1]),
    ['Tampere', 'Helsinki', 'Turku']);
  assert.match(selector[1], /<option value="Tampere" selected>Tampere<\/option>/);
  assert.doesNotMatch(html, /<datalist|known-plants/);
});

test('a different plant selection survives list refreshes and is submitted unchanged', async () => {
  for (const [plant, fetchList] of [
    ['Helsinki', async () => listResponse([record(42, 'Tampere')])],
    ['Turku', async () => ({ ok: false, json: async () => ({ message: 'Saved requests could not be loaded.' }) })],
  ]) {
    const f = browser(true, undefined, fetchList);
    f.elements['new-request'].click();
    f.elements.plant.value = plant;
    await new Promise(setImmediate);
    await f.elements.refresh.click();
    assert.equal(f.elements.plant.value, plant);
    await submit(f);
    assert.equal(JSON.parse(f.calls.find(({ url }) => url === '/checkout').options.body).plant, plant);
    assert.equal(f.elements['receipt-detail'].textContent, `Steel plate · 20 units · ${plant}`);
  }
});

function listResponse(requests, hasMore = false) {
  return { ok: true, json: async () => ({ success: true, requests, limit: 100, hasMore }) };
}

function record(id, plant = 'Lyon', material = 'Wear plate') {
  return { request_id: String(id), plant, material, quantity: 4, created_at: '2026-10-22T10:00:00Z' };
}

function deleteButton(fixture, row = 0) {
  return fixture.elements['request-rows'].children[row].children[5].children[0];
}

test('row deletion requires confirmation, describes the exact request and cancels without a write', async () => {
  const material = '<img src=x onerror=alert(1)>';
  const f = browser(true, undefined, async () => listResponse([record('9007199254740993', 'Tampere', material)]));
  await new Promise(setImmediate);
  const button = deleteButton(f);
  assert.equal(button['aria-label'], 'Delete request #9007199254740993');
  button.click();
  assert.equal(f.elements['delete-dialog'].open, true);
  assert.equal(f.elements['delete-title'].textContent, 'Delete request #9007199254740993?');
  assert.equal(f.elements['delete-description'].textContent, `${material} · 4 units · Tampere`);
  assert.deepEqual(f.elements['delete-description'].children, []);
  assert.equal(f.elements.focused, f.elements['cancel-delete']);
  f.elements['cancel-delete'].click();
  assert.equal(f.elements['delete-dialog'].open, false);
  assert.equal(f.elements.focused, button);
  button.click();
  f.elements['delete-dialog'].cancel({ preventDefault() {} });
  assert.equal(f.elements['delete-dialog'].open, false);
  await f.elements['confirm-delete'].click();
  assert.equal(f.calls.filter(({ options }) => options?.method === 'DELETE').length, 0);
});

test('confirmed deletion sends one exact ID, refreshes the list and corrects an emptied final page', async () => {
  let data = Array.from({ length: 11 }, (_, i) => record(i + 1));
  const f = browser(true, undefined, async () => listResponse(data), undefined, async (url) => {
    assert.equal(url, '/material-requests/1');
    data = data.filter((item) => item.request_id !== '1');
    return { ok: true, json: async () => ({ success: true, requestId: '1' }) };
  });
  await new Promise(setImmediate);
  f.elements.next.click();
  assert.equal(f.elements['page-info'].textContent, '11-11 of 11 requests');
  deleteButton(f).click();
  await f.elements['confirm-delete'].click();
  assert.equal(f.calls.filter(({ options }) => options?.method === 'DELETE').length, 1);
  assert.equal(f.calls.filter(({ url }) => url === '/material-requests').length, 2);
  assert.equal(f.elements.result.textContent, 'Request deleted #1');
  assert.equal(f.elements['request-count'].textContent, '10');
  assert.equal(f.elements['page-info'].textContent, '1-10 of 10 requests');
  assert.equal(f.elements['delete-dialog'].open, false);
  assert.equal(f.elements.focused, f.elements['new-request']);
  assert.equal(f.calls.filter(({ url }) => url === '/checkout').length, 0);
  assert.equal(f.elements.attempts.textContent, '');
});

test('pending deletion prevents duplicate writes, simulation, submission and premature row removal', async () => {
  let finish;
  const f = browser(true, undefined, async () => listResponse([record(42)]), undefined,
    () => new Promise((resolve) => { finish = resolve; }));
  await new Promise(setImmediate);
  deleteButton(f).click();
  const pending = f.elements['confirm-delete'].click();
  assert.equal(f.elements['confirm-delete'].textContent, 'Deleting...');
  assert.equal(f.elements['confirm-delete'].disabled, true);
  assert.equal(f.elements['cancel-delete'].disabled, true);
  assert.equal(f.elements['new-request'].disabled, true);
  assert.equal(deleteButton(f).disabled, true);
  assert.equal(f.elements['request-rows'].children[0].children[0].textContent, '#42');
  await f.elements['confirm-delete'].click();
  f.elements['cancel-delete'].click();
  f.elements['delete-dialog'].cancel({ preventDefault() {} });
  assert.equal(f.elements['delete-dialog'].open, true);
  f.elements.start.click();
  await submit(f);
  await f.elements.refresh.click();
  assert.equal(f.calls.filter(({ options }) => options?.method === 'DELETE').length, 1);
  assert.equal(f.calls.filter(({ url }) => url === '/checkout').length, 0);
  assert.equal(f.calls.filter(({ url }) => url === '/material-requests').length, 1);
  finish({ ok: true, json: async () => ({ success: true, requestId: '42' }) });
  await pending;
  assert.equal(f.calls.filter(({ url }) => url === '/material-requests').length, 2);
  assert.equal(f.elements['new-request'].disabled, false);
});

test('successful deletion retains filters and stays successful when its follow-up read fails', async () => {
  let reads = 0;
  const f = browser(true, undefined, async () => ++reads === 1 ? listResponse([record(42), record(43)]) : {
    ok: false, json: async () => ({ message: 'Saved requests could not be loaded.' }),
  }, undefined, async () => ({ ok: true, json: async () => ({ success: true, requestId: '42' }) }));
  await new Promise(setImmediate);
  f.elements.search.value = '#42';
  f.elements.search.input();
  deleteButton(f).click();
  await f.elements['confirm-delete'].click();
  assert.equal(f.elements.result.textContent, 'Request deleted #42');
  assert.equal(f.elements.result.dataset.state, 'success');
  assert.equal(f.elements.search.value, '#42');
  assert.equal(f.elements['page-info'].textContent, '0 matching requests');
  assert.equal(f.elements['request-count'].textContent, '1');
  assert.equal(f.elements['list-error'].hidden, false);
  assert.match(f.elements['list-error'].textContent, /last loaded requests/);
});

test('failed or unconfirmed deletions retain the row and are never automatically retried', async () => {
  for (const fetchDelete of [
    async () => ({ ok: false, status: 503, json: async () => ({ success: false, message: 'Deletion could not be confirmed.' }) }),
    async () => { throw new Error('Connection interrupted'); },
    async () => ({ ok: true, json: async () => ({ success: true, requestId: '43' }) }),
  ]) {
    const f = browser(true, undefined, async () => listResponse([record(42)]), undefined, fetchDelete);
    await new Promise(setImmediate);
    deleteButton(f).click();
    await f.elements['confirm-delete'].click();
    assert.equal(f.elements.result.dataset.state, 'failure');
    assert.match(f.elements.result.textContent, /could not be confirmed/);
    assert.equal(f.elements['request-rows'].children[0].children[0].textContent, '#42');
    assert.equal(f.elements['delete-dialog'].open, false);
    assert.equal(f.calls.filter(({ options }) => options?.method === 'DELETE').length, 1);
    assert.equal(f.elements.focused, deleteButton(f));
  }
});

test('a concurrently deleted row is reconciled by refresh without claiming this client deleted it', async () => {
  let data = [record(42)];
  const f = browser(true, undefined, async () => listResponse(data), undefined, async () => {
    data = [];
    return { ok: false, status: 404, json: async () => ({ success: false, message: 'Request not found. It may already have been deleted.' }) };
  });
  await new Promise(setImmediate);
  deleteButton(f).click();
  await f.elements['confirm-delete'].click();
  assert.match(f.elements.result.textContent, /already have been deleted/);
  assert.equal(f.elements.result.dataset.state, 'failure');
  assert.equal(f.elements['request-count'].textContent, '0');
  assert.equal(f.elements['request-rows'].children[0].children[0].children[0].textContent, 'No requests yet');
});

test('navigation aborts pending deletion and history restoration never replays it', async () => {
  const f = browser(true, undefined, async () => listResponse([record(42)]), undefined,
    (url, { signal }) => new Promise((resolve, reject) => {
      signal.addEventListener('abort', () => reject(signal.reason), { once: true });
    }));
  await new Promise(setImmediate);
  deleteButton(f).click();
  const pending = f.elements['confirm-delete'].click();
  const callsAtLeave = f.calls.length;
  f.events.pagehide();
  await pending;
  assert.equal(f.calls.length, callsAtLeave);
  assert.equal(f.calls.find(({ options }) => options?.method === 'DELETE').options.signal.aborted, true);
  assert.match(f.elements.result.textContent, /could not be confirmed/);
  f.events.pageshow({ persisted: true });
  await new Promise(setImmediate);
  assert.equal(f.calls.filter(({ options }) => options?.method === 'DELETE').length, 1);
  assert.equal(f.elements['delete-dialog'].open, false);
});

test('row deletion is unavailable while simulation is running or a list refresh is pending', async () => {
  let finish;
  let reads = 0;
  const f = browser(true, undefined, () => ++reads === 1 ? Promise.resolve(listResponse([record(42)]))
    : new Promise((resolve) => { finish = resolve; }));
  await new Promise(setImmediate);
  f.elements.start.click();
  assert.equal(deleteButton(f).disabled, true);
  deleteButton(f).click();
  assert.notEqual(f.elements['delete-dialog'].open, true);
  await new Promise(setImmediate);
  f.elements.stop.click();
  const refreshing = f.elements.refresh.click();
  assert.equal(deleteButton(f).disabled, true);
  deleteButton(f).click();
  assert.notEqual(f.elements['delete-dialog'].open, true);
  finish(listResponse([record(42)]));
  await refreshing;
  assert.equal(deleteButton(f).disabled, false);
  assert.equal(f.calls.filter(({ options }) => options?.method === 'DELETE').length, 0);
});

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
  f.elements.plant.value = 'Turku';
  await submit(f);
  assert.equal(f.elements['request-dialog'].open, false);
  assert.equal(f.elements['sim-material'].textContent, 'Crusher liner');
  assert.equal(f.elements['sim-plant'].textContent, 'Turku');
  assert.equal(f.calls.filter(({ url }) => url === '/checkout').length, 0);
  f.elements['new-request'].click();
  assert.equal(f.elements.checkout.textContent, 'Submit request');
});

test('cancelled drawer edits do not silently change simulation values', () => {
  const f = browser();
  f.elements['configure-simulation'].click();
  f.elements.material.value = 'Unsaved edit';
  f.elements.quantity.value = '0';
  f.elements.plant.value = 'Helsinki';
  f.elements['cancel-request'].click();
  assert.equal(f.elements.material.value, 'Steel plate');
  assert.equal(Number(f.elements.quantity.value), 20);
  assert.equal(f.elements['sim-material'].textContent, 'Steel plate');
  assert.equal(f.elements.plant.value, 'Tampere');
  assert.equal(f.elements['sim-plant'].textContent, 'Tampere');
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

test('filtering while the first read is pending preserves the loading state', async () => {
  let finish;
  const f = browser(true, undefined, () => new Promise((resolve) => { finish = resolve; }));
  f.elements.search.value = 'Wear plate';
  f.elements.search.input();
  assert.equal(f.elements['request-count'].textContent, 'Loading');
  assert.equal(f.elements['page-info'].textContent, 'Loading requests...');
  assert.equal(f.elements['request-rows'].children[0].children[0].children[0].textContent, 'Loading saved requests...');
  finish({ ok: false, json: async () => ({ message: 'Saved requests could not be loaded.' }) });
  await new Promise(setImmediate);
  assert.equal(f.elements['request-count'].textContent, 'Unavailable');
  assert.equal(f.elements['request-rows'].children[0].children[0].children[0].textContent, 'Requests unavailable');
});

test('stopping an outstanding simulation aborts it without starting a follow-up health request', async () => {
  const f = browser(true, ({ signal }) => new Promise((resolve, reject) => {
    signal.addEventListener('abort', () => reject(signal.reason), { once: true });
  }));
  await new Promise(setImmediate);
  f.elements.start.click();
  const countAtStop = f.calls.length;
  f.elements.stop.click();
  await new Promise(setImmediate);
  assert.equal(f.calls.length, countAtStop);
  assert.equal(f.calls.find(({ url }) => url === '/checkout').options.signal.aborted, true);
  assert.equal(f.timers.size, 0);
  assert.equal(f.elements.checkout.disabled, false);
  assert.match(f.elements.result.textContent, /could not be confirmed/);
});

test('Stop aborts an in-flight health read and cancellation is not reported as an outage', async () => {
  let healthReads = 0;
  const f = browser(true, undefined, undefined, ({ signal }) => ++healthReads === 1
    ? Promise.resolve({ ok: true })
    : new Promise((resolve, reject) => {
      signal.addEventListener('abort', () => reject(signal.reason), { once: true });
    }));
  await new Promise(setImmediate);
  f.elements.start.click();
  await new Promise(setImmediate);
  const health = f.calls.filter(({ url }) => url === '/healthz').at(-1);
  f.elements.stop.click();
  await new Promise(setImmediate);
  assert.equal(health.options.signal.aborted, true);
  assert.equal(f.elements.health.textContent, 'Application is running');
});

test('a late successful save after pagehide keeps its receipt but starts no new reads', async () => {
  let finish;
  const f = browser(true, () => new Promise((resolve) => { finish = resolve; }));
  await new Promise(setImmediate);
  const pending = submit(f);
  const countAtLeave = f.calls.length;
  f.events.pagehide();
  finish({ ok: true, json: async () => ({ success: true, requestId: '42' }) });
  await pending;
  assert.equal(f.elements.result.textContent, 'Request saved #42');
  assert.equal(f.calls.length, countAtLeave);
  assert.equal(f.timers.size, 0);
});

test('history restoration resumes read-only state, not the simulation, and reports stale refreshes', async () => {
  let reads = 0;
  const f = browser(true, undefined, async () => ++reads === 1
    ? listResponse([record(42)])
    : { ok: false, json: async () => ({ message: 'Saved requests could not be loaded.' }) });
  await new Promise(setImmediate);
  f.elements.start.click();
  await new Promise(setImmediate);
  f.events.pagehide();
  f.events.pageshow({ persisted: true });
  await new Promise(setImmediate);
  assert.equal(reads, 2);
  assert.equal(f.elements.loop.textContent, 'Stopped');
  assert.equal(f.calls.filter(({ url }) => url === '/checkout').length, 1);
  assert.equal(f.timers.size, 0);
  assert.equal(f.elements['list-error'].hidden, false);
  assert.match(f.elements['list-error'].textContent, /Showing the last loaded requests/);
  assert.equal(f.elements['request-rows'].children[0].children[0].textContent, '#42');
});

test('history restoration ignores the aborted list snapshot and drains a queued fresh read', async () => {
  let finishFirst;
  let reads = 0;
  const f = browser(true, undefined, () => ++reads === 1
    ? new Promise((resolve) => { finishFirst = resolve; })
    : Promise.resolve(listResponse([record(43)])));
  f.events.pagehide();
  assert.equal(f.calls.find(({ url }) => url === '/material-requests').options.signal.aborted, true);
  f.events.pageshow({ persisted: true });
  assert.equal(reads, 1);
  finishFirst(listResponse([record(42)]));
  await new Promise(setImmediate);
  assert.equal(reads, 2);
  assert.equal(f.elements['request-rows'].children[0].children[0].textContent, '#43');
  assert.equal(f.elements['list-error'].hidden, true);
  assert.equal(f.calls.filter(({ url }) => url === '/checkout').length, 0);
});

test('a superseded health response cannot overwrite the newest process health', async () => {
  let finishFirst;
  let reads = 0;
  const f = browser(true, undefined, undefined, () => ++reads === 1
    ? new Promise((resolve) => { finishFirst = resolve; })
    : Promise.resolve({ ok: true }));
  await submit(f);
  await new Promise(setImmediate);
  assert.equal(f.calls.find(({ url }) => url === '/healthz').options.signal.aborted, true);
  finishFirst({ ok: false });
  await new Promise(setImmediate);
  assert.equal(f.elements.health.textContent, 'Application is running');
});
