'use strict';

const elements = Object.fromEntries([
  'health', 'result', 'timing', 'checkout', 'start', 'stop', 'loop',
  'attempts', 'successes', 'failures', 'material', 'quantity', 'plant',
  'request-form', 'receipt-detail', 'feedback', 'dismiss-feedback', 'form-status',
  'request-dialog', 'dialog-title', 'new-request', 'close-request', 'cancel-request',
  'configure-simulation', 'sim-material', 'sim-quantity', 'sim-plant',
  'show-requests', 'show-demo', 'requests-view', 'demo-view', 'view-label',
  'request-panel', 'request-rows', 'request-count', 'list-error', 'search',
  'plant-filter', 'sort', 'refresh', 'page-info', 'previous', 'next',
  'coverage', 'updated',
  'delete-dialog', 'delete-title', 'delete-description', 'cancel-delete', 'confirm-delete',
].map((id) => [id, document.getElementById(id)]));
const PAGE_SIZE = 10;
let records = [];
let loaded = false;
let loading = false;
let refreshQueued = false;
let page = 0;
let dialogMode = 'create';
let dialogValues;
let lastSavedId;
let running = false;
let busy = false;
let leaving = false;
let nextAttempt;
let deadlineTimer;
let deadline = 0;
let attempts = 0;
let successes = 0;
let failures = 0;
let activeRequest;
let activeList;
let activeHealth;
let pendingDeletion;
let deleting = false;
let activeDeletion;
let deleteButtons = [];

function node(tag, text, className) {
  const element = document.createElement(tag);
  if (text !== undefined) element.textContent = text;
  if (className) element.className = className;
  return element;
}

function renderRequests() {
  const firstLoad = loading && !loaded;
  const query = elements.search.value.trim().toLocaleLowerCase();
  const filtered = records.filter((record) =>
    (!elements['plant-filter'].value || record.plant === elements['plant-filter'].value) &&
    `#${record.request_id} ${record.material} ${record.plant}`.toLocaleLowerCase().includes(query));
  const direction = elements.sort.value === 'oldest' ? 1 : -1;
  filtered.sort((a, b) => direction * (Date.parse(a.created_at) - Date.parse(b.created_at) ||
    (BigInt(a.request_id) > BigInt(b.request_id) ? 1 : BigInt(a.request_id) < BigInt(b.request_id) ? -1 : 0)));
  page = Math.min(page, Math.max(0, Math.ceil(filtered.length / PAGE_SIZE) - 1));
  const visible = filtered.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE);
  deleteButtons = [];
  const rows = visible.map((record) => {
    const row = node('tr');
    if (record.request_id === lastSavedId) row.className = 'new-row';
    const plant = node('td', undefined, 'plant-cell');
    plant.append(node('span', record.plant, 'plant-name'));
    const created = node('td', undefined, 'created-cell');
    const time = node('time');
    const date = new Date(record.created_at);
    time.dateTime = record.created_at;
    time.title = date.toISOString();
    time.append(node('span', date.toLocaleDateString(undefined, { day: '2-digit', month: 'short', year: 'numeric' })),
      node('span', date.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' }), 'created-time'));
    created.append(time);
    const actions = node('td', undefined, 'actions-cell');
    const remove = node('button', undefined, 'icon-button delete-request');
    remove.type = 'button';
    remove.title = `Delete request #${record.request_id}`;
    remove.setAttribute('aria-label', remove.title);
    remove.dataset.requestId = record.request_id;
    remove.disabled = busy || running || deleting || loading;
    const icon = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    icon.setAttribute('viewBox', '0 0 24 24');
    icon.setAttribute('aria-hidden', 'true');
    const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    path.setAttribute('d', 'M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7');
    icon.append(path);
    remove.append(icon);
    remove.addEventListener('click', () => openDelete(record));
    deleteButtons.push(remove);
    actions.append(remove);
    row.append(node('td', `#${record.request_id}`, 'request-id'),
      node('td', record.material, 'material-cell'),
      node('td', record.quantity.toLocaleString(), 'numeric'), plant, created, actions);
    return row;
  });
  if (!rows.length) {
    const row = node('tr');
    const cell = node('td', undefined, 'empty-state');
    cell.colSpan = 6;
    cell.append(node('strong', firstLoad ? 'Loading saved requests...' : !loaded ? 'Requests unavailable' :
      records.length ? 'No matching requests' : 'No requests yet'));
    cell.append(node('div', firstLoad ? 'Waiting for the saved request list.' : !loaded ? 'Refresh the list to try again.' :
      records.length ? 'Try a different material, request ID, or plant.' : 'Create a material request to get started.'));
    if (loaded && records.length) {
      const clear = node('button', 'Clear filters', 'secondary');
      clear.type = 'button';
      clear.addEventListener('click', () => {
        elements.search.value = '';
        elements['plant-filter'].value = '';
        page = 0;
        renderRequests();
      });
      cell.append(clear);
    }
    row.append(cell);
    rows.push(row);
  }
  elements['request-rows'].replaceChildren(...rows);
  elements['request-count'].textContent = loaded ? records.length.toLocaleString() : firstLoad ? 'Loading' : 'Unavailable';
  elements['page-info'].textContent = firstLoad ? 'Loading requests...' : !loaded ? 'Not loaded' : filtered.length
    ? `${page * PAGE_SIZE + 1}-${Math.min((page + 1) * PAGE_SIZE, filtered.length)} of ${filtered.length} requests`
    : '0 matching requests';
  elements.previous.disabled = page === 0;
  elements.next.disabled = (page + 1) * PAGE_SIZE >= filtered.length;
}

function validList(data) {
  return data?.success === true && Array.isArray(data.requests) &&
    Number.isInteger(data.limit) && data.limit >= 1 && data.limit <= 100 &&
    data.requests.length <= data.limit && typeof data.hasMore === 'boolean' &&
    data.requests.every((record) => record && typeof record.request_id === 'string' &&
      /^[1-9][0-9]{0,18}$/.test(record.request_id) &&
      typeof record.material === 'string' && record.material.length > 0 && record.material.length <= 120 &&
      typeof record.plant === 'string' && record.plant.length > 0 && record.plant.length <= 80 &&
      Number.isInteger(record.quantity) && record.quantity >= 1 && record.quantity <= 1000000 &&
      typeof record.created_at === 'string' && Number.isFinite(Date.parse(record.created_at)));
}

async function loadRequests() {
  if (leaving) return;
  if (loading || deleting) { refreshQueued = true; return; }
  refreshQueued = false;
  loading = true;
  const controller = new AbortController();
  activeList = controller;
  updateButtons();
  elements['request-panel'].setAttribute('aria-busy', 'true');
  if (!loaded) renderRequests();
  try {
    const response = await fetch('/material-requests', {
      signal: AbortSignal.any([controller.signal, AbortSignal.timeout(7000)]),
    });
    const data = await response.json();
    if (controller.signal.aborted) return;
    if (!response.ok) throw new Error(typeof data.message === 'string' ? data.message : 'Saved requests could not be loaded.');
    if (!validList(data)) throw new Error('The server returned an unexpected request list. Try refreshing.');
    records = data.requests;
    loaded = true;
    const selection = elements['plant-filter'].value;
    const plants = [...new Set(records.map((record) => record.plant))].sort((a, b) => a.localeCompare(b));
    if (selection && !plants.includes(selection)) plants.push(selection);
    elements['plant-filter'].replaceChildren(...['', ...plants].map((plant) => {
      const option = node('option', plant || 'All plants');
      option.value = plant;
      return option;
    }));
    elements['plant-filter'].value = selection;
    elements['list-error'].hidden = true;
    elements.coverage.textContent = `${data.hasMore ? `Showing the latest ${data.limit} saved requests. ` : ''}Times shown in your local timezone.`;
    elements.updated.textContent = `Updated ${new Date().toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })}`;
  } catch (error) {
    if (!leaving && !controller.signal.aborted) {
      elements['list-error'].textContent = `${error.message || 'Saved requests could not be loaded.'}${loaded ? ' Showing the last loaded requests.' : ''}`;
      elements['list-error'].hidden = false;
    }
  } finally {
    loading = false;
    activeList = undefined;
    updateButtons();
    elements['request-panel'].setAttribute('aria-busy', 'false');
    if (!leaving) renderRequests();
    if (refreshQueued && !leaving) { refreshQueued = false; void loadRequests(); }
  }
}

function updateButtons() {
  for (const id of ['checkout', 'start', 'new-request', 'configure-simulation', 'material', 'quantity', 'plant']) {
    elements[id].disabled = busy || running || deleting;
  }
  elements.stop.disabled = !running;
  elements['close-request'].disabled = busy;
  elements['cancel-request'].disabled = busy;
  elements.checkout.textContent = busy ? 'Submitting...' : dialogMode === 'simulation' ? 'Use these values' : 'Submit request';
  elements.loop.dataset.state = running ? 'running' : 'idle';
  elements.refresh.disabled = loading || deleting;
  elements['cancel-delete'].disabled = deleting;
  elements['confirm-delete'].disabled = deleting || loading;
  elements['confirm-delete'].textContent = deleting ? 'Deleting...' : 'Delete request';
  elements['delete-dialog'].setAttribute('aria-busy', String(deleting));
  for (const button of deleteButtons) button.disabled = busy || running || deleting || loading;
}

function requestValues() {
  return { material: elements.material.value, quantity: Number(elements.quantity.value), plant: elements.plant.value };
}

function updateSimulationValues() {
  const request = requestValues();
  elements['sim-material'].textContent = request.material;
  elements['sim-quantity'].textContent = `${request.quantity.toLocaleString()} units`;
  elements['sim-plant'].textContent = request.plant;
}

function setResult(message, state) {
  elements.feedback.hidden = false;
  elements.feedback.dataset.state = state;
  elements.result.textContent = message;
  elements.result.dataset.state = state;
  elements['form-status'].textContent = message;
  elements['form-status'].dataset.state = state;
  elements['form-status'].hidden = false;
}

function openRequest(mode) {
  if (busy || running || deleting) return;
  dialogMode = mode;
  dialogValues = requestValues();
  elements['dialog-title'].textContent = mode === 'simulation' ? 'Simulation values' : 'New material request';
  elements['form-status'].hidden = true;
  updateButtons();
  elements['request-dialog'].showModal();
  elements.material.focus();
}

function cancelRequest() {
  if (busy) return;
  for (const [id, value] of Object.entries(dialogValues)) elements[id].value = value;
  updateSimulationValues();
  elements['request-dialog'].close();
}

function openDelete(record) {
  if (leaving || busy || running || deleting || loading) return;
  pendingDeletion = record;
  elements['delete-title'].textContent = `Delete request #${record.request_id}?`;
  elements['delete-description'].textContent = `${record.material} · ${record.quantity.toLocaleString()} units · ${record.plant}`;
  elements['delete-dialog'].showModal();
  elements['cancel-delete'].focus();
}

function focusDeleteAction(requestId) {
  const button = deleteButtons.find((item) => item.dataset.requestId === requestId && !item.disabled);
  (button || elements['new-request']).focus();
}

function cancelDelete() {
  if (deleting) return;
  const requestId = pendingDeletion?.request_id;
  pendingDeletion = undefined;
  elements['delete-dialog'].close();
  focusDeleteAction(requestId);
}

async function deleteRequest() {
  if (leaving || busy || running || deleting || loading || !pendingDeletion) return;
  const record = pendingDeletion;
  deleting = true;
  updateButtons();
  const controller = new AbortController();
  activeDeletion = controller;
  let failureMessage;
  try {
    const response = await fetch(`/material-requests/${record.request_id}`, {
      method: 'DELETE',
      signal: AbortSignal.any([controller.signal, AbortSignal.timeout(7000)]),
    });
    const data = await response.json();
    if (!response.ok || data.success !== true) {
      failureMessage = typeof data.message === 'string' ? data.message : undefined;
      throw new Error('Deletion failed');
    }
    if (data.requestId !== record.request_id) throw new Error('Unexpected deletion response');
    records = records.filter((item) => item.request_id !== record.request_id);
    setResult(`Request deleted #${record.request_id}`, 'success');
  } catch {
    setResult(failureMessage || 'Deletion could not be confirmed. Refresh the list to check the outcome before trying again.', 'failure');
  } finally {
    elements['receipt-detail'].textContent = `${record.material} · ${record.quantity.toLocaleString()} units · ${record.plant}`;
    activeDeletion = undefined;
    pendingDeletion = undefined;
    deleting = false;
    elements['delete-dialog'].close();
    updateButtons();
    if (!leaving) {
      renderRequests();
      await loadRequests();
      if (!leaving) focusDeleteAction(record.request_id);
    }
  }
}

function stopTraffic(message = 'Stopped') {
  running = false;
  clearTimeout(nextAttempt);
  clearTimeout(deadlineTimer);
  activeRequest?.abort();
  activeHealth?.abort();
  elements.loop.textContent = message;
  updateButtons();
}

async function checkHealth() {
  if (leaving) return;
  activeHealth?.abort();
  const controller = new AbortController();
  activeHealth = controller;
  try {
    const response = await fetch('/healthz', {
      signal: AbortSignal.any([controller.signal, AbortSignal.timeout(7000)]),
    });
    if (controller.signal.aborted) return;
    if (!response.ok) throw new Error('Unavailable');
    elements.health.textContent = 'Application is running';
    elements.health.dataset.state = 'success';
  } catch {
    if (!leaving && !controller.signal.aborted) {
      elements.health.textContent = 'Application unavailable';
      elements.health.dataset.state = 'failure';
    }
  } finally {
    if (activeHealth === controller) activeHealth = undefined;
  }
}

function validForm() {
  return ['material', 'quantity', 'plant'].every((id) => elements[id].reportValidity());
}

async function checkout() {
  if (leaving || busy || deleting || !validForm()) return;
  const request = requestValues();
  const simulated = running;
  busy = true;
  updateButtons();
  updateSimulationValues();
  setResult('Submitting material request...', 'pending');
  elements['receipt-detail'].textContent = `${request.material} · ${request.quantity.toLocaleString()} units · ${request.plant}`;
  const started = performance.now();
  const controller = new AbortController();
  activeRequest = controller;
  attempts += 1;
  elements.attempts.textContent = attempts;
  let failureMessage;
  let saved = false;
  try {
    const response = await fetch('/checkout', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(request),
      signal: AbortSignal.any([controller.signal, AbortSignal.timeout(7000)]),
    });
    const data = await response.json();
    if (!response.ok || data.success !== true) {
      failureMessage = typeof data.message === 'string' ? data.message : undefined;
      throw new Error('Submission failed');
    }
    if ((data.requestId !== undefined && (typeof data.requestId !== 'string' || !/^[1-9][0-9]{0,18}$/.test(data.requestId))) ||
        (data.requestId === undefined && typeof data.message !== 'string')) {
      throw new Error('Unexpected submission response');
    }
    successes += 1;
    saved = true;
    lastSavedId = data.requestId;
    setResult(data.requestId ? `Request saved #${data.requestId}` : data.message, 'success');
    if (!simulated) {
      elements['request-dialog'].close();
      page = 0;
      if (!controller.signal.aborted) void loadRequests();
    }
  } catch {
    failures += 1;
    setResult(failureMessage || 'Material request could not be confirmed. Check the outcome before retrying.', 'failure');
  } finally {
    activeRequest = undefined;
    busy = false;
    elements.successes.textContent = successes;
    elements.failures.textContent = failures;
    elements.timing.textContent = `Latest attempt: ${Math.round(performance.now() - started)} ms · ${new Date().toLocaleTimeString()}`;
    updateButtons();
    if (saved && !simulated) elements['new-request'].focus();
    if (!controller.signal.aborted && (!simulated || running)) void checkHealth();
  }
}

async function trafficStep() {
  if (!running) return;
  if (Date.now() >= deadline) { stopTraffic('Finished after 10 minutes'); return; }
  await checkout();
  if (running) nextAttempt = setTimeout(trafficStep, 3000);
}

function showView(demo) {
  elements['requests-view'].hidden = demo;
  elements['demo-view'].hidden = !demo;
  elements['show-requests'].setAttribute('aria-current', demo ? 'false' : 'page');
  elements['show-demo'].setAttribute('aria-current', demo ? 'page' : 'false');
  elements['view-label'].textContent = demo ? 'Demo controls' : 'Material requests';
  if (!demo) void loadRequests();
}

elements['show-requests'].addEventListener('click', () => showView(false));
elements['show-demo'].addEventListener('click', () => showView(true));
elements['new-request'].addEventListener('click', () => openRequest('create'));
elements['configure-simulation'].addEventListener('click', () => openRequest('simulation'));
elements['cancel-delete'].addEventListener('click', cancelDelete);
elements['confirm-delete'].addEventListener('click', deleteRequest);
elements['delete-dialog'].addEventListener('cancel', (event) => {
  event.preventDefault();
  cancelDelete();
});
for (const id of ['close-request', 'cancel-request']) {
  elements[id].addEventListener('click', cancelRequest);
}
elements['request-dialog'].addEventListener('cancel', (event) => {
  if (busy) event.preventDefault();
  else cancelRequest();
});
elements['dismiss-feedback'].addEventListener('click', () => { elements.feedback.hidden = true; });
elements['request-form'].addEventListener('submit', (event) => {
  event.preventDefault();
  if (dialogMode === 'simulation') {
    if (validForm()) { updateSimulationValues(); elements['request-dialog'].close(); }
    return;
  }
  return checkout();
});
elements.start.addEventListener('click', () => {
  if (leaving || busy || running || deleting || !validForm()) return;
  running = true;
  deadline = Date.now() + 10 * 60 * 1000;
  deadlineTimer = setTimeout(() => stopTraffic('Finished after 10 minutes'), 10 * 60 * 1000);
  elements.loop.textContent = 'Running';
  updateButtons();
  void trafficStep();
});
elements.stop.addEventListener('click', () => stopTraffic());
elements.refresh.addEventListener('click', () => loadRequests());
for (const [id, event] of [['search', 'input'], ['plant-filter', 'change'], ['sort', 'change']]) {
  elements[id].addEventListener(event, () => { page = 0; renderRequests(); });
}
elements.previous.addEventListener('click', () => { page = Math.max(0, page - 1); renderRequests(); });
elements.next.addEventListener('click', () => { page += 1; renderRequests(); });
window.addEventListener('pagehide', () => {
  leaving = true;
  refreshQueued = false;
  stopTraffic();
  activeList?.abort();
  activeDeletion?.abort();
});
window.addEventListener('pageshow', (event) => {
  if (!event.persisted) return;
  leaving = false;
  void checkHealth();
  void loadRequests();
});
void checkHealth();
void loadRequests();
