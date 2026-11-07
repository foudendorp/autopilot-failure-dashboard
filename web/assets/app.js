// Autopilot Dashboard front end. Vanilla JS, no external dependencies.
// Every value from Graph or logs is rendered through h()/textContent (see dom.js).
'use strict';
import { h, clear, $, $all, NA, show, fmtDate, fmtDuration, safeUrl } from './dom.js';
import { barChart, dailyTrend } from './charts.js';
import { passesFilters, filterBreakdown } from './filters.js';

const state = {
  boot: null,
  data: null,
  view: 'overview',
  sort: { key: 'eventDateTime', dir: -1 },
  filters: { flow: '', status: '', profile: '', model: '', search: '' },
  selectedId: null,
  presenting: false,
  slide: 0,
  pollTimer: null,
  authTimer: null,
  diagTarget: null,
};

const STATUS_ORDER = ['Success', 'Failed', 'In progress', 'Not attempted', 'Not available'];

// ------------------------------------------------------------------------------------ API
async function api(method, path, body, isForm = false) {
  const headers = { 'X-CSRF-Token': state.boot?.csrfToken ?? '' };
  let payload;
  if (body !== undefined && !isForm) { headers['Content-Type'] = 'application/json'; payload = JSON.stringify(body); }
  if (isForm) payload = body;
  const res = await fetch(path, { method, headers, body: payload, credentials: 'same-origin', cache: 'no-store' });
  let json = null;
  try { json = await res.json(); } catch { /* non-JSON */ }
  if (res.status === 401 && json?.code === 'not_signed_in') {
    await loadAuth();
    throw new Error(json.error ?? 'Not signed in.');
  }
  if (!res.ok) throw new Error(json?.error ?? `Request failed (${res.status})`);
  return json;
}

// ------------------------------------------------------------------------------------ banners
function banner(kind, message, opts = {}) {
  const host = $('#banners');
  if (opts.id) host.querySelector(`[data-id="${opts.id}"]`)?.remove();
  const el = h('div', { class: `banner ${kind}`, role: kind === 'error' ? 'alert' : 'status', dataset: opts.id ? { id: opts.id } : undefined },
    h('span', { text: message }),
    opts.action ? h('button', { type: 'button', class: 'btn small', on: { click: opts.action.fn } }, opts.action.label) : null,
    h('button', { type: 'button', class: 'btn subtle small', 'aria-label': 'Dismiss', on: { click: () => el.remove() } }, '✕'));
  host.appendChild(el);
  if (opts.timeout) setTimeout(() => el.remove(), opts.timeout);
}

// ------------------------------------------------------------------------------------ boot
async function boot() {
  try {
    const res = await fetch('/api/bootstrap', { cache: 'no-store' });
    state.boot = await res.json();
  } catch {
    banner('error', 'Could not reach the local server. Is Start-AutopilotDashboard.ps1 still running?');
    return;
  }
  const to = new Date();
  const from = new Date(Date.now() - state.boot.defaultDays * 86400000);
  $('#fromDate').value = from.toISOString().slice(0, 10);
  $('#toDate').value = to.toISOString().slice(0, 10);
  $('#anonToggle').checked = !!state.boot.anonymize;
  wireEvents();
  renderAccount(state.boot.auth);
  if (state.boot.auth.message) banner(state.boot.auth.status === 'signedIn' ? 'info' : 'warn', state.boot.auth.message, { id: 'auth' });
  await loadData();
  startAuthWatch();
  const r = await fetch('/api/refresh/status', { cache: 'no-store' }).then(x => x.json()).catch(() => null);
  if (r?.running) pollRefresh();
}

function wireEvents() {
  $all('.tab').forEach(btn => btn.addEventListener('click', () => setView(btn.dataset.view)));
  $('#refreshBtn').addEventListener('click', startRefresh);
  $('#demoBtn').addEventListener('click', loadDemo);
  $('#anonToggle').addEventListener('change', e => setAnonymize(e.target.checked));
  $('#exportBtn').addEventListener('click', openExport);
  $('#presentBtn').addEventListener('click', () => setPresentation(!state.presenting));
  for (const [id, key] of [['#fFlow', 'flow'], ['#fStatus', 'status'], ['#fProfile', 'profile'], ['#fModel', 'model']]) {
    $(id).addEventListener('change', e => { state.filters[key] = e.target.value; render(); });
  }
  let t;
  $('#fSearch').addEventListener('input', e => { clearTimeout(t); t = setTimeout(() => { state.filters.search = e.target.value; render(); }, 200); });
  $('#fReset').addEventListener('click', resetFilters);
  $('#fromDate').addEventListener('change', render);
  $('#toDate').addEventListener('change', render);
  $all('dialog [data-close]').forEach(b => b.addEventListener('click', () => b.closest('dialog').close()));
  $('#exportAck').addEventListener('change', e => { $('#exportGo').disabled = !e.target.checked; });
  $('#exportGo').addEventListener('click', doExport);
  $('#diagAck').addEventListener('change', e => { $('#diagDlGo').disabled = !e.target.checked; });
  $('#diagDlGo').addEventListener('click', doDiagDownload);
  document.addEventListener('keydown', onKey);
}

function resetFilters() {
  state.filters = { flow: '', status: '', profile: '', model: '', search: '' };
  $('#fSearch').value = '';
  if (state.data?.meta?.from) {
    $('#fromDate').value = state.data.meta.from.slice(0, 10);
    $('#toDate').value = state.data.meta.to.slice(0, 10);
  }
  render();
}

// ------------------------------------------------------------------------------------ auth
function renderAccount(auth) {
  const host = clear($('#account'));
  state.boot.auth = auth;
  if (auth.status === 'signedIn' && auth.account) {
    host.appendChild(h('div', { class: 'who' },
      h('span', { class: 'who-name', text: auth.account.name || auth.account.upn || 'Signed in' }),
      h('span', { class: 'who-sub', text: auth.account.upn || '' }),
      h('span', { class: 'who-sub', text: `Tenant ${auth.account.tenantId}${auth.account.domain ? ` (${auth.account.domain})` : ''}` }),
      auth.authMode === 'graphCli' ? h('span', { class: 'who-sub', text: 'via Microsoft Graph Command Line Tools' }) : null));
    host.appendChild(h('button', { type: 'button', class: 'btn', on: { click: signOut } }, 'Sign out'));
  } else {
    if (!auth.configured) {
      host.appendChild(h('span', { class: 'who-sub', text: 'Sign-in not configured: set "authMode": "graphCli", or tenantId and clientId, in config\\settings.json and restart' }));
    }
    host.appendChild(h('button', { type: 'button', class: 'btn primary', disabled: !auth.configured, on: { click: signIn } }, 'Sign in'));
  }
  $('#refreshBtn').disabled = auth.status !== 'signedIn';
  $('#refreshBtn').title = auth.status === 'signedIn' ? 'Retrieve data from Intune for the selected date range' : 'Sign in to retrieve tenant data';
  $('#demoBtn').disabled = auth.status === 'signedIn';
  $('#demoBtn').title = auth.status === 'signedIn' ? 'Sign out to use demo mode (tenant and demo data are never mixed)' : 'Load fictional demo data';
}

async function loadAuth() {
  try {
    const auth = await fetch('/api/auth/status', { cache: 'no-store' }).then(r => r.json());
    const wasSignedIn = state.boot.auth.status === 'signedIn';
    renderAccount(auth);
    if (auth.status === 'expired' || (wasSignedIn && auth.status !== 'signedIn')) {
      banner('warn', auth.message || 'Your session expired. Sign in again.', { id: 'auth', action: auth.configured ? { label: 'Sign in', fn: signIn } : null });
    }
  } catch { /* server offline */ }
}

function startAuthWatch() {
  clearInterval(state.authTimer);
  state.authTimer = setInterval(() => { if (state.boot.auth.status === 'signedIn') loadAuth(); }, 60000);
}

async function signIn() {
  try {
    const r = await api('POST', '/api/auth/start', {});
    window.location.assign(r.url);
  } catch (e) { banner('error', e.message); }
}

async function signOut() {
  try {
    await api('POST', '/api/auth/signout', {});
    await loadAuth();
    banner('info', 'Signed out. Tokens and tenant data were removed from memory.', { id: 'auth', timeout: 6000 });
    await loadData();
  } catch (e) { banner('error', e.message); }
}

// ------------------------------------------------------------------------------------ data
async function loadData() {
  try {
    state.data = await api('GET', '/api/data');
    for (const k of ['deployments', 'improvements', 'logs']) state.data[k] = asList(state.data[k]);
    if (state.data.meta) state.data.meta.sources = asList(state.data.meta.sources);
  } catch (e) { banner('error', `Could not load data: ${e.message}`); return; }
  if (state.data.meta?.rulesError) banner('warn', state.data.meta.rulesError, { id: 'rules' });
  const st = $('#dataStatus');
  if (!state.data.hasData) st.textContent = 'No data loaded. Sign in and refresh, or use Demo mode.';
  else {
    const m = state.data.meta;
    st.textContent = `${m.mode === 'demo' ? 'DEMO DATA (fictional)' : 'Tenant data'} · ${fmtDate(m.from, false)} – ${fmtDate(m.to, false)} · last refreshed ${fmtDate(m.refreshedUtc)}`;
    st.classList.toggle('demo', m.mode === 'demo');
  }
  fillFilterOptions();
  render();
}

async function loadDemo() {
  try {
    await api('POST', '/api/demo', {});
    banner('info', 'Demo mode: showing fictional Contoso data. No tenant is contacted.', { id: 'demo', timeout: 8000 });
    await loadData();
    resetFilters();
  } catch (e) { banner('error', e.message); }
}

async function startRefresh() {
  const from = $('#fromDate').value, to = $('#toDate').value;
  if (!from || !to) { banner('error', 'Select a date range first.'); return; }
  try {
    await api('POST', '/api/refresh', { from, to });
    pollRefresh();
  } catch (e) { banner('error', e.message); }
}

function pollRefresh() {
  const bar = $('#progress');
  bar.classList.remove('hidden');
  $('#refreshBtn').disabled = true;
  clearInterval(state.pollTimer);
  state.pollTimer = setInterval(async () => {
    let r;
    try { r = await fetch('/api/refresh/status', { cache: 'no-store' }).then(x => x.json()); } catch { return; }
    $('#progressFill').style.width = `${Math.min(100, r.percent ?? 0)}%`;
    $('#progressText').textContent = `${r.message ?? ''} (${r.percent ?? 0}%)`;
    if (!r.running) {
      clearInterval(state.pollTimer);
      setTimeout(() => bar.classList.add('hidden'), 1200);
      $('#refreshBtn').disabled = state.boot.auth.status !== 'signedIn';
      if (r.error) { banner('error', `Refresh failed: ${r.error}`, { id: 'refresh' }); await loadAuth(); }
      else banner(r.message?.startsWith('Completed with') ? 'warn' : 'info', r.message ?? 'Refresh completed', { id: 'refresh', timeout: 10000 });
      await loadData();
    }
  }, 1000);
}

async function setAnonymize(on) {
  try {
    await api('POST', '/api/settings/anonymize', { enabled: on });
    state.boot.anonymize = on;
    document.body.classList.toggle('anon', on);
    await loadData();
    if (state.selectedId && $('#detailDialog').open) openDetail(state.selectedId);
  } catch (e) { banner('error', e.message); $('#anonToggle').checked = !on; }
}

// ------------------------------------------------------------------------------------ filtering
// Defensive: a list must always be an array, even if the server ever sends a single object.
const asList = v => (Array.isArray(v) ? v : (v == null ? [] : [v]));
function deployments() { return asList(state.data?.deployments); }

function filtered() {
  const from = $('#fromDate').value, to = $('#toDate').value;
  return deployments().filter(d => passesFilters(d, state.filters, from, to));
}

function fillFilterOptions() {
  const ds = deployments();
  const uniq = (fn) => [...new Set(ds.map(fn))].sort((a, b) => String(a).localeCompare(String(b)));
  const fill = (id, values, current, label) => {
    const sel = clear($(id));
    sel.appendChild(h('option', { value: '' }, `All ${label}`));
    values.forEach(v => sel.appendChild(h('option', { value: v, selected: v === current }, v)));
  };
  fill('#fFlow', uniq(d => d.flow), state.filters.flow, 'flows');
  fill('#fStatus', STATUS_ORDER.filter(s => ds.some(d => d.status === s)), state.filters.status, 'statuses');
  fill('#fProfile', uniq(d => d.profile || NA), state.filters.profile, 'profiles');
  fill('#fModel', uniq(d => d.model || NA), state.filters.model, 'models');
}

function stats(rows) {
  const count = s => rows.filter(d => d.status === s).length;
  const success = count('Success'), failed = count('Failed'), na = count('Not available');
  const other = rows.length - success - failed - na;
  const durations = rows.filter(d => (d.status === 'Success' || d.status === 'Failed') && d.durationSec > 0).map(d => d.durationSec).sort((a, b) => a - b);
  const median = durations.length ? (durations.length % 2 ? durations[(durations.length - 1) / 2] : (durations[durations.length / 2 - 1] + durations[durations.length / 2]) / 2) : null;
  return { total: rows.length, success, failed, na, other, rate: (success + failed) ? success / (success + failed) : null, median, durationsKnown: durations.length };
}

function countBy(rows, fn) {
  const m = new Map();
  rows.forEach(r => { for (const k of [].concat(fn(r) ?? [])) { if (k === null || k === undefined || k === '') continue; m.set(k, (m.get(k) ?? 0) + 1); } });
  return [...m.entries()].map(([label, value]) => ({ label, value })).sort((a, b) => b.value - a.value || String(a.label).localeCompare(String(b.label)));
}

function failureBreakdowns(rows) {
  const failed = rows.filter(d => d.status === 'Failed');
  return {
    phase: countBy(failed, d => d.phase || NA),
    item: countBy(failed, d => [...new Set((d.failedItems ?? []).filter(i => i.status === 'error').map(i => i.name))]),
    profile: countBy(failed, d => d.profile || NA),
    model: countBy(failed, d => d.model || NA),
    code: countBy(failed, d => d.errorCodes?.length ? d.errorCodes : [NA]),
  };
}

function trend(rows) {
  const days = new Map();
  const from = $('#fromDate').value || state.data?.meta?.from?.slice(0, 10);
  const to = $('#toDate').value || state.data?.meta?.to?.slice(0, 10);
  if (from && to) {
    for (let d = new Date(`${from}T00:00:00Z`); d <= new Date(`${to}T00:00:00Z`); d = new Date(d.getTime() + 86400000)) {
      days.set(d.toISOString().slice(0, 10), { day: d.toISOString().slice(0, 10), success: 0, failed: 0, na: 0, other: 0 });
    }
  }
  rows.forEach(r => {
    if (!r.day) return;
    if (!days.has(r.day)) days.set(r.day, { day: r.day, success: 0, failed: 0, na: 0, other: 0 });
    const e = days.get(r.day);
    if (r.status === 'Success') e.success++; else if (r.status === 'Failed') e.failed++; else if (r.status === 'Not available') e.na++; else e.other++;
  });
  return [...days.values()].sort((a, b) => a.day.localeCompare(b.day));
}

// ------------------------------------------------------------------------------------ rendering
function setView(view) {
  state.view = view;
  $all('.tab').forEach(t => t.classList.toggle('active', t.dataset.view === view));
  $('#filters').classList.toggle('hidden', view === 'sources' || view === 'diagnostics');
  render();
  $('#main').focus({ preventScroll: true });
}

function render() {
  if (state.presenting) { renderPresentation(); return; }
  const main = clear($('#main'));
  if (!state.data) return;
  if (!state.data.hasData && state.view !== 'sources' && state.view !== 'diagnostics') { main.appendChild(emptyState()); return; }
  const views = { overview: renderOverview, deployments: renderTable, improvements: renderImprovements, diagnostics: renderDiagnostics, sources: renderSources };
  main.appendChild(views[state.view]());
}

function emptyState() {
  const auth = state.boot.auth;
  return h('div', { class: 'empty' },
    h('h2', { text: 'No deployment data loaded' }),
    h('p', { text: auth.status === 'signedIn' ? 'Select a date range and select Refresh to retrieve Autopilot data from Intune (read-only).' : 'Sign in to your Intune tenant and select Refresh, or select Demo mode to explore the dashboard with fictional data.' }),
    h('div', { class: 'empty-actions' },
      auth.status === 'signedIn' ? h('button', { type: 'button', class: 'btn primary', on: { click: startRefresh } }, 'Refresh now')
        : h('button', { type: 'button', class: 'btn primary', disabled: !auth.configured, on: { click: signIn } }, 'Sign in'),
      auth.status !== 'signedIn' ? h('button', { type: 'button', class: 'btn', on: { click: loadDemo } }, 'Demo mode') : null));
}

function kpiTiles(st) {
  const tile = (label, value, sub, cls = '') => h('div', { class: `kpi ${cls}` }, h('span', { class: 'kpi-label', text: label }), h('span', { class: 'kpi-value', text: value }), sub ? h('span', { class: 'kpi-sub', text: sub }) : null);
  return h('div', { class: 'kpis' },
    tile('Total deployments', String(st.total), st.na ? `${st.na} with status not available` : 'all with a known status'),
    tile('Success rate', st.rate === null ? NA : `${(st.rate * 100).toFixed(1)}%`, `${st.success} succeeded of ${st.success + st.failed} completed`, 'ok'),
    tile('Failures', String(st.failed), st.other ? `${st.other} in progress / not attempted` : '', 'bad'),
    tile('Median duration', st.median === null ? NA : fmtDuration(st.median), st.durationsKnown ? `based on ${st.durationsKnown} completed deployments` : 'no durations reported'));
}

function card(title, body, opts = {}) {
  return h('section', { class: `card ${opts.cls ?? ''}` }, h('div', { class: 'card-head' }, h('h2', { text: title }), opts.badge ?? null), body);
}

function searchFor(label) {
  if (label === NA) return;
  state.filters.search = String(label);
  $('#fSearch').value = String(label);
  setView('deployments');
}

function renderOverview() {
  const rows = filtered();
  const st = stats(rows);
  const b = failureBreakdowns(rows);
  const frag = h('div', { class: 'grid' });
  frag.appendChild(kpiTiles(st));
  frag.appendChild(card('Deployments per day', dailyTrend(trend(rows)), { cls: 'span-2' }));
  frag.appendChild(card('Failures by phase', barChart(b.phase, { onClick: v => { state.filters.status = 'Failed'; searchFor(v); }, ariaLabel: 'Failures by phase' })));
  frag.appendChild(card('Failures by error code', barChart(b.code, { onClick: searchFor, ariaLabel: 'Failures by error code' })));
  frag.appendChild(card('Failures by app or policy', barChart(b.item, { onClick: searchFor, empty: 'No failing apps or policies known. Graph may not provide them; uploaded diagnostics add ESP-tracked app errors.', ariaLabel: 'Failures by app or policy' })));
  frag.appendChild(card('Failures by deployment profile', barChart(b.profile, { ariaLabel: 'Failures by profile' })));
  frag.appendChild(card('Failures by device model', barChart(b.model, { ariaLabel: 'Failures by model' })));
  const imp = (state.data.improvements ?? []).slice(0, 3);
  frag.appendChild(card('Top structural improvements', imp.length ? h('ol', { class: 'imp-mini' }, imp.map(i => h('li', {}, h('strong', { text: i.structuralAction }), h('span', { class: 'muted', text: ` · ${i.deployments} failed deployment(s)` })))) : h('p', { class: 'muted', text: 'No rule-based findings yet.' }),
    { badge: h('button', { type: 'button', class: 'btn subtle small', on: { click: () => setView('improvements') } }, 'View all') }));
  return frag;
}

const COLUMNS = [
  { key: 'eventDateTime', label: 'Date', fmt: d => fmtDate(d.eventDateTime) },
  { key: 'deviceName', label: 'Device', fmt: d => show(d.deviceName) },
  { key: 'serial', label: 'Serial', fmt: d => show(d.serial) },
  { key: 'upn', label: 'User', fmt: d => show(d.upn) },
  { key: 'model', label: 'Model', fmt: d => show(d.model) },
  { key: 'profile', label: 'Profile', fmt: d => show(d.profile) },
  { key: 'flow', label: 'Flow', fmt: d => show(d.flow) },
  { key: 'status', label: 'Status', fmt: d => d.status },
  { key: 'phase', label: 'Phase', fmt: d => show(d.phase) },
  { key: 'errorCodes', label: 'Error', fmt: d => (d.errorCodes?.length ? d.errorCodes.join(', ') : '–') },
  { key: 'durationSec', label: 'Duration', fmt: d => fmtDuration(d.durationSec) },
];

function renderTable() {
  const rows = filtered().slice();
  const { key, dir } = state.sort;
  rows.sort((a, b) => {
    const av = Array.isArray(a[key]) ? a[key].join(',') : a[key];
    const bv = Array.isArray(b[key]) ? b[key].join(',') : b[key];
    if (av === bv) return 0;
    if (av === null || av === undefined || av === '') return 1;    // missing values always last
    if (bv === null || bv === undefined || bv === '') return -1;
    return (typeof av === 'number' ? av - bv : String(av).localeCompare(String(bv))) * dir;
  });
  const limit = 1000;
  const table = h('table', { class: 'data' },
    h('thead', {}, h('tr', {}, COLUMNS.map(c => h('th', { scope: 'col', 'aria-sort': c.key === key ? (dir > 0 ? 'ascending' : 'descending') : 'none' },
      h('button', { type: 'button', class: 'sort', on: { click: () => { state.sort = { key: c.key, dir: state.sort.key === c.key ? -state.sort.dir : 1 }; render(); } } },
        c.label, c.key === key ? (dir > 0 ? ' ▲' : ' ▼') : ''))))),
    h('tbody', {}, rows.slice(0, limit).map(d => h('tr', { class: `row-${d.status.replace(/\s/g, '-').toLowerCase()}`, tabindex: 0, on: { click: () => openDetail(d.id), keydown: e => { if (e.key === 'Enter') openDetail(d.id); } } },
      COLUMNS.map(c => h('td', { class: c.key === 'status' ? 'status-cell' : '', text: c.fmt(d) }))))));
  return h('div', {},
    h('p', { class: 'muted', text: `${rows.length} deployment(s) match the filters${rows.length > limit ? `; showing the first ${limit}` : ''}. Select a row for details.` }),
    h('div', { class: 'table-wrap' }, table));
}

function confidenceBadge(f) {
  return h('span', { class: `badge conf-${f.confidence}`, text: `${f.label} · ${f.confidence} confidence` });
}

function findingCard(f) {
  const src = safeUrl(f.sourceUrl);
  return h('article', { class: `finding ${f.ambiguous ? 'ambiguous' : ''}` },
    h('header', {}, h('span', { class: 'rule-id', text: f.ruleId }), confidenceBadge(f), f.ambiguous ? h('span', { class: 'badge warn', text: 'Ambiguous signal' }) : null),
    h('p', { class: 'muted small', text: `Signal: ${f.signal} · Phase: ${f.phase}${f.contextMatch === 'match' ? ' · matches deployment context' : f.contextMatch === 'unknown' ? ' · deployment context not available' : ''}` }),
    h('dl', { class: 'kv' },
      h('dt', { text: f.label }), h('dd', { text: f.likelyCause }),
      h('dt', { text: 'Recommended fix' }), h('dd', { text: f.recommendedFix }),
      h('dt', { text: 'Structural action' }), h('dd', { text: f.structuralAction }),
      h('dt', { text: 'Evidence' }), h('dd', {}, h('ul', { class: 'evidence' }, (f.evidence ?? []).map(e => h('li', {}, h('span', { class: 'ev-src', text: e.source }), ' ', h('span', { text: e.detail || `${e.key} = ${e.value}` }))))),
      h('dt', { text: 'Source' }), h('dd', {}, src ? h('a', { href: src, target: '_blank', rel: 'noopener noreferrer' }, src) : NA)));
}

function factGrid(pairs) {
  return h('dl', { class: 'facts' }, pairs.map(([k, v, cls]) => h('div', { class: 'fact' }, h('dt', { text: k }), h('dd', { class: cls ?? '', text: show(v) }))));
}

function renderDetail(d) {
  const body = h('div', { class: 'detail' });
  body.appendChild(factGrid([
    ['Status', d.status, `st-${d.status.replace(/\s/g, '-').toLowerCase()}`], ['Phase', d.phase + (d.phaseSource === 'rule' ? ' (from matching rule; Graph did not report the phase)' : '')],
    ['Flow', d.flow], ['Date', fmtDate(d.eventDateTime)], ['Device', d.deviceName], ['Serial number', d.serial], ['User', d.upn],
    ['Manufacturer / model', [d.manufacturer, d.model].filter(Boolean).join(' ') || null], ['Group tag', d.groupTag],
    ['Profile (event)', d.profile], ['Assigned profile', d.assignedProfile], ['Intended profile', d.intendedProfile + (d.profileMismatch ? ' ⚠ differs from assigned' : '')],
    ['ESP profile', d.espProfile], ['OS version', d.osVersion], ['Total duration', fmtDuration(d.durationSec)],
    ['Device preparation / setup / account', [d.durations?.devicePreparation, d.durations?.deviceSetup, d.durations?.accountSetup].map(fmtDuration).join(' / ')],
    ['Enrollment state', d.enrollmentState], ['Device setup status', d.deviceSetupStatus], ['Account setup status', d.accountSetupStatus],
    ['Enrollment failure details', d.enrollmentFailure],
  ]));
  if (d.dataGaps?.length) body.appendChild(h('p', { class: 'note', text: `Not available in the Graph data for this deployment: ${d.dataGaps.join(', ')}.` }));

  body.appendChild(h('h3', { text: 'Likely and possible causes' }));
  if (d.findings?.length) {
    if (d.findings.some(f => f.ambiguous)) body.appendChild(h('p', { class: 'note', text: 'Some evidence matches more than one rule. All candidate causes are shown; confirm with logs before acting.' }));
    d.findings.forEach(f => body.appendChild(findingCard(f)));
  } else {
    body.appendChild(h('p', { class: 'muted', text: d.status === 'Failed' ? 'No rule matched the available evidence. Review the evidence below, or upload diagnostics for this device on the Diagnostics & logs tab.' : 'No findings (deployment did not fail).' }));
  }

  body.appendChild(h('h3', { text: 'Timeline' }));
  body.appendChild(d.timeline?.length ? h('ol', { class: 'timeline' }, d.timeline.map(t => h('li', { class: `tl-${t.kind}` }, h('time', { text: fmtDate(t.time) }), h('strong', { text: t.label }), t.detail ? h('span', { class: 'muted', text: ` ${t.detail}` }) : null))) : h('p', { class: 'muted', text: NA }));

  body.appendChild(h('h3', { text: 'Evidence' }));
  body.appendChild(d.evidence?.length ? h('div', { class: 'table-wrap' }, h('table', { class: 'data compact' },
    h('thead', {}, h('tr', {}, ['Source', 'Type', 'Key', 'Value'].map(x => h('th', { text: x })))),
    h('tbody', {}, d.evidence.map(e => h('tr', {}, h('td', { text: e.source }), h('td', { text: e.kind }), h('td', { text: show(e.key) }), h('td', { class: 'wrap', text: show(e.value) })))))) : h('p', { class: 'muted', text: 'No failure evidence reported.' }));

  body.appendChild(h('h3', { text: 'Apps and policies with errors' }));
  if (!d.policyDetailsLoaded && !d.failedItems?.length) body.appendChild(h('p', { class: 'muted', text: 'Not available: Graph returned no policy or app status for this deployment (see Data sources). Upload diagnostics for this device to see ESP-tracked app errors.' }));
  else body.appendChild(d.failedItems?.length ? h('table', { class: 'data compact' },
    h('thead', {}, h('tr', {}, ['Name', 'Type', 'Status', 'Error code', 'Tracked by ESP'].map(x => h('th', { text: x })))),
    h('tbody', {}, d.failedItems.map(i => h('tr', {}, h('td', { text: i.name }), h('td', { text: show(i.type) }), h('td', { text: i.status }), h('td', { text: show(i.errorCode) }), h('td', { text: i.trackedOnEsp ? 'Yes' : 'No' })))))
    : h('p', { class: 'muted', text: 'None reported.' }));

  if (d.logAnalysisIds?.length) {
    body.appendChild(h('h3', { text: 'Matched diagnostics' }));
    (state.data.logs ?? []).filter(l => d.logAnalysisIds.includes(l.id)).forEach(l => body.appendChild(h('p', { text: `${l.fileName} (matched by ${l.matchedBy ?? 'device'}) – analysed ${fmtDate(l.analyzedUtc)}` })));
  }

  if (state.data.meta.mode === 'tenant' && d.managedDeviceId) {
    const host = h('div', { class: 'diag-host' });
    body.appendChild(h('h3', { text: 'Intune diagnostics for this device' }));
    body.appendChild(h('button', { type: 'button', class: 'btn', on: { click: () => listDiagnostics(d.managedDeviceId, host) } }, 'List available diagnostics'));
    body.appendChild(host);
  }
  return body;
}

function openDetail(id) {
  const d = deployments().find(x => x.id === id);
  if (!d) return;
  state.selectedId = id;
  $('#detailTitle').textContent = `${show(d.deviceName)} · ${d.status}`;
  const body = clear($('#detailBody'));
  body.appendChild(renderDetail(d));
  const dlg = $('#detailDialog');
  if (!dlg.open) dlg.showModal();
}

function renderImprovements() {
  const imp = state.data.improvements ?? [];
  if (!imp.length) return h('div', { class: 'empty' }, h('h2', { text: 'No structural improvements yet' }), h('p', { text: 'Improvements are derived from rule findings on failed deployments.' }));
  return h('div', {},
    h('p', { class: 'muted', text: 'Ranked by impact: number of failed deployments × rule confidence (ambiguous and generic findings count less). Based on the full loaded data set.' }),
    h('ol', { class: 'improvements' }, imp.map(i => h('li', { class: 'card' },
      h('div', { class: 'imp-head' }, h('span', { class: 'rank', text: `#${i.rank}` }), h('h3', { text: i.structuralAction })),
      h('p', {}, h('strong', { text: `${i.deployments} failed deployment(s)` }), i.ambiguousDeployments ? h('span', { class: 'muted', text: ` · ${i.ambiguousDeployments} with an ambiguous signal` }) : null,
        h('span', { class: 'muted', text: ` · score ${i.score} · phases: ${i.phases.join(', ')}` })),
      h('p', { class: 'small' }, 'Rules: ', i.ruleIds.map((r, ix) => [ix ? ', ' : '', h('button', { type: 'button', class: 'linklike', on: { click: () => searchFor(r) } }, r)])),
      h('p', { class: 'small' }, 'Sources: ', i.sourceUrls.map((u, ix) => [ix ? ' · ' : '', safeUrl(u) ? h('a', { href: u, target: '_blank', rel: 'noopener noreferrer' }, new URL(u).pathname.split('/').filter(Boolean).pop()) : NA]))))));
}

// ------------------------------------------------------------------------------------ diagnostics
function renderDiagnostics() {
  const wrap = h('div', { class: 'grid' });
  const capHost = h('div', {});
  const mode = state.data?.meta?.mode;
  wrap.appendChild(card('Diagnostics capability test', h('div', {},
    h('p', { text: 'Checks whether the signed-in account can list and download Intune "Collect diagnostics" archives through Microsoft Graph. The test only reads (GET) and requests a download URL for an existing collection (the single documented POST exception). It never starts a new collection on a device.' }),
    h('button', { type: 'button', class: 'btn primary', disabled: !(state.boot.auth.status === 'signedIn' || mode === 'demo'), on: { click: () => runCapability(capHost) } }, 'Run capability test'),
    capHost), { cls: 'span-2' }));

  const fileInput = h('input', { type: 'file', accept: '.zip,.cab', id: 'uploadInput', class: 'visually-hidden' });
  const drop = h('div', { class: 'dropzone', tabindex: 0 },
    h('p', {}, h('strong', { text: 'Drop a .zip or .cab here' }), ' or ', h('label', { for: 'uploadInput', class: 'linklike', text: 'choose a file' })),
    h('p', { class: 'muted small', text: `Supported: mdmdiagnosticstool output (.cab, e.g. mdmdiagnosticstool.exe -area Autopilot;TPM -cab C:\\temp\\ap.cab) and Intune Collect diagnostics archives (.zip). Max ${state.boot.maxUploadMB} MB. Files are extracted to a temporary folder, parsed and deleted immediately.` }),
    fileInput);
  fileInput.addEventListener('change', () => { if (fileInput.files[0]) uploadFile(fileInput.files[0]); });
  drop.addEventListener('dragover', e => { e.preventDefault(); drop.classList.add('over'); });
  drop.addEventListener('dragleave', () => drop.classList.remove('over'));
  drop.addEventListener('drop', e => { e.preventDefault(); drop.classList.remove('over'); if (e.dataTransfer.files[0]) uploadFile(e.dataTransfer.files[0]); });
  drop.addEventListener('keydown', e => { if (e.key === 'Enter') fileInput.click(); });
  wrap.appendChild(card('Upload diagnostics', h('div', {}, drop,
    h('div', { class: 'row-actions' },
      h('button', { type: 'button', class: 'btn', on: { click: analyzeSample } }, 'Analyze sample diagnostics (fictional)'),
      (state.data?.logs ?? []).length ? h('button', { type: 'button', class: 'btn subtle', on: { click: clearLogs } }, 'Clear analysed logs') : null)), { cls: 'span-2' }));

  const logs = state.data?.logs ?? [];
  wrap.appendChild(card(`Analysed diagnostics (${logs.length})`, logs.length ? h('div', {}, logs.slice().reverse().map(renderLogAnalysis)) : h('p', { class: 'muted', text: 'Nothing analysed yet. Only the parsed summary is kept in memory; it is cleared when you sign out or refresh.' }), { cls: 'span-2' }));
  return wrap;
}

function renderLogAnalysis(l) {
  const reg = l.autopilotRegistry ?? {};
  const matched = (l.matchedDeploymentIds ?? []).map(id => deployments().find(d => d.id === id)).filter(Boolean);
  return h('article', { class: `log ${l.status}` },
    h('header', {}, h('strong', { text: l.fileName }), h('span', { class: `badge ${l.status === 'ok' ? 'ok' : l.status === 'warning' ? 'warn' : 'bad'}`, text: l.status }), h('span', { class: 'muted small', text: ` ${l.origin} · ${fmtDate(l.analyzedUtc)}` })),
    l.message ? h('p', { class: l.status === 'error' ? 'error-text' : 'note', text: l.message }) : null,
    factGrid([
      ['Serial number', l.serialNumber], ['Intune device ID (EntDMID)', l.managedDeviceId],
      ['Matched deployment', matched.length ? matched.map(d => `${show(d.deviceName)} (${fmtDate(d.eventDateTime)}, by ${l.matchedBy})`).join('; ') : 'No matching deployment in the loaded data'],
      ['TenantMatched', reg.TenantMatched, reg.TenantMatched === 0 ? 'bad-text' : ''], ['IsAutopilotDisabled', reg.IsAutopilotDisabled, reg.IsAutopilotDisabled === 1 ? 'bad-text' : ''],
      ['CloudAssignedTenantDomain', reg.CloudAssignedTenantDomain], ['CloudAssignedTenantId', reg.CloudAssignedTenantId], ['AadTenantId', reg.AadTenantId],
      ['Files parsed', (l.filesFound ?? []).join(', ') || null],
    ]),
    matched.length ? h('button', { type: 'button', class: 'btn small', on: { click: () => openDetail(matched[0].id) } }, 'Open matched deployment') : null,
    (l.espTracking ?? []).length ? h('details', { open: true }, h('summary', { text: `ESP tracking (${l.espTracking.length})` }),
      h('table', { class: 'data compact' }, h('thead', {}, h('tr', {}, ['Phase', 'Item', 'InstallationState'].map(x => h('th', { text: x })))),
        h('tbody', {}, l.espTracking.map(e => h('tr', { class: e.installationState === 4 ? 'row-failed' : '' }, h('td', { text: e.scope }), h('td', { text: e.item }), h('td', { text: `${e.installationState} (${e.stateName})` })))))) : null,
    (l.autopilotEvents ?? []).length ? h('details', {}, h('summary', { text: `Autopilot events (${l.autopilotEvents.length})` }),
      h('table', { class: 'data compact' }, h('thead', {}, h('tr', {}, ['Time', 'ID', 'Level', 'Message'].map(x => h('th', { text: x })))),
        h('tbody', {}, l.autopilotEvents.slice(-200).map(e => h('tr', {}, h('td', { text: fmtDate(e.time) }), h('td', { text: e.id }), h('td', { text: e.level }), h('td', { class: 'wrap', text: e.message })))))) : null,
    (l.textSignals ?? []).length ? h('details', {}, h('summary', { text: `Matching log lines (${l.textSignals.length})` }),
      h('ul', { class: 'evidence' }, l.textSignals.map(t => h('li', {}, h('span', { class: 'ev-src', text: `${t.file}:${t.line}` }), ' ', h('span', { text: t.text }))))) : null,
    l.communityOutput ? h('details', {}, h('summary', { text: 'Get-AutopilotDiagnosticsCommunity output (optional supplement)' }), h('pre', { text: l.communityOutput })) : null,
    h('h4', { text: 'Findings from this archive' }),
    (l.findings ?? []).length ? h('div', {}, l.findings.map(findingCard)) : h('p', { class: 'muted', text: 'No rule matched the parsed evidence.' }));
}

async function runCapability(host) {
  clear(host).appendChild(h('p', { class: 'muted', text: 'Testing…' }));
  try {
    const cap = await api('POST', '/api/diagnostics/capability', {});
    clear(host);
    host.appendChild(h('p', { class: cap.canDownload ? 'ok-text' : 'note', text: cap.summary }));
    host.appendChild(h('table', { class: 'data compact' }, h('thead', {}, h('tr', {}, ['Step', 'Method', 'Endpoint (beta)', 'Result', 'Details'].map(x => h('th', { text: x })))),
      h('tbody', {}, (cap.steps ?? []).map(s => h('tr', {}, h('td', { text: s.name }), h('td', { text: s.method }), h('td', { class: 'mono', text: s.endpoint }), h('td', {}, h('span', { class: `badge ${s.status === 'ok' ? 'ok' : s.status === 'skipped' ? '' : 'bad'}`, text: s.status })), h('td', { class: 'wrap', text: s.message }))))));
    if (cap.docsNote) host.appendChild(h('p', { class: 'small muted' }, cap.docsNote, ' ', safeUrl(cap.docsUrl) ? h('a', { href: cap.docsUrl, target: '_blank', rel: 'noopener noreferrer' }, 'Microsoft Learn: Collect diagnostics') : null));
    if (!cap.canDownload) host.appendChild(h('p', { class: 'note', text: 'Fallback: in the Intune admin center open the device, then Monitor > Device diagnostics (or Diagnostics > Download after an Autopilot failure). Download the .zip and upload it below.' }));
    if (cap.canList && cap.collections?.length) host.appendChild(collectionsTable(cap.collections));
  } catch (e) { clear(host).appendChild(h('p', { class: 'error-text', text: e.message })); }
}

function collectionsTable(list) {
  return h('table', { class: 'data compact' }, h('thead', {}, h('tr', {}, ['Requested', 'Status', 'Size', 'Expires', ''].map(x => h('th', { text: x })))),
    h('tbody', {}, list.map(c => h('tr', {}, h('td', { text: fmtDate(c.requested) }), h('td', { text: show(c.status) }), h('td', { text: c.sizeInKB ? `${Math.round(c.sizeInKB / 1024)} MB` : NA }), h('td', { text: fmtDate(c.expires) }),
      h('td', {}, /^completed$/i.test(c.status ?? '') ? [
        h('button', { type: 'button', class: 'btn small', on: { click: () => openDiagDownload(c) } }, 'Download'), ' ',
        h('button', { type: 'button', class: 'btn small', on: { click: () => analyzeCollection(c) } }, 'Analyze')] : h('span', { class: 'muted', text: 'Not ready' }))))));
}

async function listDiagnostics(managedDeviceId, host) {
  clear(host).appendChild(h('p', { class: 'muted', text: 'Listing…' }));
  try {
    const r = await api('POST', '/api/diagnostics/list', { managedDeviceId });
    clear(host).appendChild(r.collections?.length ? collectionsTable(r.collections) : h('p', { class: 'muted', text: 'No diagnostics collections exist for this device (they are kept for 28 days).' }));
  } catch (e) {
    clear(host).appendChild(h('p', { class: 'error-text', text: e.message }));
    host.appendChild(h('p', { class: 'note', text: 'You can still download the diagnostics in the Intune admin center and upload them on the Diagnostics & logs tab.' }));
  }
}

function openDiagDownload(c) {
  state.diagTarget = c;
  $('#diagAck').checked = false;
  $('#diagDlGo').disabled = true;
  $('#diagDownloadDialog').showModal();
}

async function doDiagDownload() {
  const c = state.diagTarget;
  $('#diagDownloadDialog').close();
  try {
    const r = await api('POST', '/api/diagnostics/fetch', { managedDeviceId: c.managedDeviceId, requestId: c.id, action: 'download', acknowledged: true });
    triggerDownload(r.url);
  } catch (e) { banner('error', e.message); }
}

async function analyzeCollection(c) {
  banner('info', 'Downloading and analysing diagnostics…', { id: 'diag' });
  try {
    await api('POST', '/api/diagnostics/fetch', { managedDeviceId: c.managedDeviceId, requestId: c.id, action: 'analyze' });
    banner('info', 'Diagnostics analysed.', { id: 'diag', timeout: 6000 });
    await loadData();
    $('#detailDialog').close();
    setView('diagnostics');
  } catch (e) { banner('error', e.message, { id: 'diag' }); }
}

async function uploadFile(file) {
  const ext = file.name.toLowerCase().slice(file.name.lastIndexOf('.'));
  if (!['.zip', '.cab'].includes(ext)) { banner('error', 'Only .zip and .cab files are supported.'); return; }
  if (file.size > state.boot.maxUploadMB * 1048576) { banner('error', `File is larger than ${state.boot.maxUploadMB} MB.`); return; }
  const fd = new FormData();
  fd.append('file', file, file.name);
  banner('info', `Analysing ${file.name}…`, { id: 'upload' });
  try {
    const r = await api('POST', '/api/logs/upload', fd, true);
    banner(r.status === 'ok' ? 'info' : 'warn', r.message || 'Analysis complete.', { id: 'upload', timeout: 8000 });
  } catch (e) { banner('error', e.message, { id: 'upload' }); }
  await loadData();
}

async function analyzeSample() {
  try {
    await api('POST', '/api/logs/sample', {});
    banner('info', 'Sample diagnostics (fictional) analysed.', { id: 'upload', timeout: 6000 });
    await loadData();
  } catch (e) { banner('error', e.message); }
}

async function clearLogs() {
  try { await api('POST', '/api/logs/clear', {}); await loadData(); } catch (e) { banner('error', e.message); }
}

// ------------------------------------------------------------------------------------ sources
// Pipeline diagnostics: counts from Graph to the screen. No tokens or personal data are shown.
function renderPipeline(host) {
  clear(host).appendChild(h('p', { class: 'muted', text: 'Loading…' }));
  api('GET', '/api/pipeline').then(p => {
    clear(host);
    const from = $('#fromDate').value, to = $('#toDate').value;
    const b = filterBreakdown(deployments(), state.filters, from, to);
    const hidden = Object.entries(b.hiddenBy).filter(([, n]) => n).map(([k, n]) => `${k}: ${n}`).join(', ');
    const g = p.graph ?? {};
    const steps = [
      ['Raw rows from Graph', g.rawRows, `${show(g.endpoint)} · ${show(g.pages)} page(s)`],
      ['Excluded by refreshed date range', g.excludedByDate, `${fmtDate(p.refresh.rangeFrom, false)} – ${fmtDate(p.refresh.rangeTo, false)}; a row is kept when any of its dates is in range`],
      ['Kept without any date', g.rowsWithoutDate, 'shown with date "Not available"'],
      ['Rows after processing', p.processing.modelRows, (p.processing.statusCounts ?? []).map(s => `${s.status}: ${s.count}`).join(', ')],
      ['Rows after browser filters', b.shown, hidden ? `hidden by ${hidden}` : 'no rows hidden by filters'],
    ];
    host.appendChild(h('table', { class: 'data compact' },
      h('thead', {}, h('tr', {}, ['Step', 'Rows', 'Details'].map(x => h('th', { text: x })))),
      h('tbody', {}, steps.map(([k, v, d]) => h('tr', {}, h('td', { text: k }), h('td', { class: 'mono', text: show(v) }), h('td', { class: 'wrap', text: d }))))));
    if (hidden) host.appendChild(h('p', { class: 'note' }, `${b.total - b.shown} row(s) hidden by the date range or filters above the table. `, h('button', { type: 'button', class: 'linklike', on: { click: () => { resetFilters(); renderPipeline(host); } } }, 'Reset filters')));

    host.appendChild(h('h3', { text: 'deploymentState values as received from Graph' }));
    host.appendChild((p.processing.rawStates ?? []).length ? h('table', { class: 'data compact' },
      h('thead', {}, h('tr', {}, ['Raw value', 'Rows', 'Shown as'].map(x => h('th', { text: x })))),
      h('tbody', {}, p.processing.rawStates.map(s => h('tr', { class: s.mappedTo === 'Not available' && s.raw !== '(empty)' ? 'row-failed' : '' }, h('td', { class: 'mono', text: s.raw }), h('td', { text: s.count }), h('td', { text: s.mappedTo })))))
      : h('p', { class: 'muted', text: NA }));
    if (p.processing.unknownStates?.length) host.appendChild(h('p', { class: 'error-text', text: `Unknown deploymentState values (shown as Not available): ${p.processing.unknownStates.join(', ')}` }));

    host.appendChild(h('h3', { text: 'Refresh, tenant and permissions' }));
    host.appendChild(factGrid([
      ['Data mode', p.mode], ['Data retrieved', fmtDate(p.refresh.dataFrom)], ['Last refresh started', fmtDate(p.refresh.lastStarted)],
      ['Last refresh finished', fmtDate(p.refresh.lastFinished)], ['Last refresh error', p.refresh.lastError || 'None', p.refresh.lastError ? 'bad-text' : ''],
      ['Signed-in tenant ID', p.auth.tenantId], ['Configured tenant', p.auth.configuredTenant], ['Authority', p.auth.authority], ['Sign-in app', p.auth.signInApp],
      ['Missing Graph permissions', p.auth.status !== 'signedIn' ? 'Not signed in' : (p.auth.missingScopes?.length ? p.auth.missingScopes.join(', ') : 'None'), p.auth.missingScopes?.length ? 'bad-text' : ''],
    ]));
    if (p.refresh.showingOlderData) host.appendChild(h('p', { class: 'note', text: 'The last refresh failed: the dashboard still shows data from an earlier refresh.' }));
    if (p.errors?.length) host.appendChild(h('ul', {}, p.errors.map(e => h('li', { class: 'error-text', text: `${e.source}: ${e.status}. ${e.message}` }))));

    host.appendChild(h('h3', { text: 'Find a deployment' }));
    const input = h('input', { type: 'search', placeholder: 'Exact event ID, serial number, device name or Intune device ID', autocomplete: 'off', class: 'grow-input' });
    const out = h('div', {});
    const go = async () => {
      clear(out).appendChild(h('p', { class: 'muted', text: 'Searching…' }));
      try {
        const r = await api('POST', '/api/pipeline/lookup', { query: input.value });
        clear(out);
        if (r.note) out.appendChild(h('p', { class: 'note', text: r.note }));
        (r.matches ?? []).forEach(m => out.appendChild(h('div', { class: 'card' },
          factGrid([['Event ID', m.eventId], ['Matched on', m.matchedOn], ['Raw deploymentState', m.rawDeploymentState], ['Shown as', m.mappedStatus],
            ['Deployment start', fmtDate(m.dates.deploymentStart)], ['Event date', fmtDate(m.dates.event)], ['Verdict', m.verdict, m.verdict === 'shown' ? 'ok-text' : 'bad-text']]),
          h('p', { text: m.explanation }),
          m.verdict === 'shown' ? h('p', { text: deployments().some(d => d.id === m.eventId && passesFilters(d, state.filters, from, to)) ? 'Visible with the current browser filters.' : 'Hidden by the current browser filters or date range.' }) : null)));
      } catch (e) { clear(out).appendChild(h('p', { class: 'error-text', text: e.message })); }
    };
    input.addEventListener('keydown', e => { if (e.key === 'Enter') go(); });
    host.appendChild(h('div', { class: 'row-actions' }, input, h('button', { type: 'button', class: 'btn', on: { click: go } }, 'Find')));
    host.appendChild(out);
  }).catch(e => { clear(host).appendChild(h('p', { class: 'error-text', text: e.message })); });
}

function renderSources() {
  const m = state.data?.meta ?? {};
  const wrap = h('div', { class: 'grid' });
  const pipeHost = h('div', {});
  wrap.appendChild(card('Data pipeline diagnostics', pipeHost, { cls: 'span-2', badge: h('button', { type: 'button', class: 'btn subtle small', on: { click: () => renderPipeline(pipeHost) } }, 'Reload') }));
  renderPipeline(pipeHost);
  const statusBadge = s => h('span', { class: `badge ${s === 'ok' || s === 'demo' ? 'ok' : s === 'partial' || s === 'skipped' ? 'warn' : 'bad'}`, text: s });
  wrap.appendChild(card('Microsoft Graph endpoints', (m.sources ?? []).length ? h('table', { class: 'data compact' },
    h('thead', {}, h('tr', {}, ['Data', 'Endpoint', 'Version', 'Status', 'Items', 'Details'].map(x => h('th', { text: x })))),
    h('tbody', {}, m.sources.map(src => h('tr', {}, h('td', { text: src.name }), h('td', { class: 'mono wrap', text: src.endpoint }), h('td', {}, src.beta ? h('span', { class: 'badge beta', text: 'BETA' }) : 'v1.0'),
      h('td', {}, statusBadge(src.status)), h('td', { text: show(src.count) }), h('td', { class: 'wrap', text: src.message || '' }))))) : h('p', { class: 'muted', text: 'No refresh has run yet.' }),
  { cls: 'span-2', badge: h('span', { class: 'badge beta', text: 'Beta endpoints can change without notice' }) }));

  const dp = m.devicePrep;
  wrap.appendChild(card('Autopilot device preparation', dp ? h('div', {},
    h('p', { class: 'note', text: dp.deploymentDataMessage }),
    h('p', { text: `Device preparation policies found: ${dp.policies?.length ?? 0}` }),
    dp.policies?.length ? h('ul', {}, dp.policies.map(p => h('li', { text: `${show(p.name)} (modified ${fmtDate(p.lastModified, false)})` }))) : null) : h('p', { class: 'muted', text: NA })));

  wrap.appendChild(card('Read-only policy', h('div', {},
    h('p', { text: 'The Graph client enforces this centrally: only GET requests to https://graph.microsoft.com are sent. Any other method or host is blocked before the request leaves the app.' }),
    h('p', {}, h('strong', { text: 'Single approved exception (POST): ' }), (state.boot.postException ?? []).map(x => [x.name, ' ', safeUrl(x.docs) ? h('a', { href: x.docs, target: '_blank', rel: 'noopener noreferrer' }, '(docs)') : null]),
      h('span', { class: 'muted', text: ` · currently ${state.boot.allowDiagPost ? 'enabled' : 'disabled'} (allowDiagnosticsDownloadPost)` })),
    h('p', {}, h('strong', { text: 'Sign-in app: ' }), show(state.boot.signInApp), h('span', { class: 'muted', text: ` · redirect URI ${show(state.boot.redirectUri)}` })),
    h('p', { text: 'Requested delegated permissions:' }),
    h('ul', { class: 'mono small' }, (state.boot.scopes ?? []).map(sc => h('li', { text: sc }))))));

  const rulesHost = h('div', {}, h('p', { class: 'muted', text: 'Loading rules…' }));
  wrap.appendChild(card(`Analysis rules (${m.ruleCount ?? '…'})`, rulesHost, { cls: 'span-2' }));
  api('GET', '/api/rules').then(r => {
    clear(rulesHost);
    if (r.error) rulesHost.appendChild(h('p', { class: 'error-text', text: r.error }));
    rulesHost.appendChild(h('p', { class: 'muted small', text: 'Edit rules.json to change rules. Changes apply on the next refresh, demo load or upload.' }));
    rulesHost.appendChild(h('div', { class: 'table-wrap' }, h('table', { class: 'data compact' },
      h('thead', {}, h('tr', {}, ['ID', 'Phase', 'Signal', 'Likely cause', 'Confidence', 'Verified', 'Source'].map(x => h('th', { text: x })))),
      h('tbody', {}, r.rules.map(rule => h('tr', {}, h('td', { class: 'mono', text: rule.id }), h('td', { text: rule.phase }), h('td', { text: rule.signal?.description ?? rule.signal?.type }),
        h('td', { class: 'wrap', text: rule.likelyCause }), h('td', { text: rule.confidence }), h('td', { class: 'small wrap', text: rule.verification ? `${rule.verification.checked}: ${rule.verification.note}` : NA }),
        h('td', {}, safeUrl(rule.sourceUrl) ? h('a', { href: rule.sourceUrl, target: '_blank', rel: 'noopener noreferrer' }, 'Microsoft Learn') : NA)))))));
  }).catch(e => { clear(rulesHost).appendChild(h('p', { class: 'error-text', text: e.message })); });
  return wrap;
}

// ------------------------------------------------------------------------------------ export
function openExport() {
  if (!state.data?.hasData) { banner('warn', 'Nothing to export yet.'); return; }
  const rows = filtered();
  $('#exportCount').textContent = `${rows.length} deployment(s) in the current filter selection will be exported, with their findings and the structural improvement list.`;
  $('#exportAnonState').textContent = state.boot.anonymize ? 'Anonymize is ON: user names, device names and serial numbers will be masked in the file.' : 'Anonymize is OFF: the file will contain real user names, device names and serial numbers.';
  $('#exportAck').checked = false;
  $('#exportGo').disabled = true;
  $('#exportDialog').showModal();
}

async function doExport() {
  const format = $all('input[name="exportFormat"]').find(r => r.checked)?.value ?? 'csv';
  const ids = filtered().map(d => d.id);
  $('#exportDialog').close();
  try {
    const r = await api('POST', '/api/export', { format, ids, acknowledged: true });
    triggerDownload(r.url);
  } catch (e) { banner('error', e.message); }
}

function triggerDownload(url) {
  const safe = safeUrl(url);
  if (!safe) { banner('error', 'Unexpected download URL.'); return; }
  const a = h('a', { href: safe, download: '' });
  document.body.appendChild(a);
  a.click();
  a.remove();
}

// ------------------------------------------------------------------------------------ presentation mode
function slides() {
  const rows = filtered();
  const st = stats(rows);
  const b = failureBreakdowns(rows);
  const big = { max: 7, labelWidth: 300, width: 860 };
  const list = [
    { title: 'Autopilot deployments at a glance', body: () => h('div', {}, kpiTiles(st), dailyTrend(trend(rows))) },
    { title: 'Where do deployments fail? (by phase)', body: () => barChart(b.phase, big) },
    { title: 'Top error codes', body: () => barChart(b.code, big) },
    { title: 'Failing apps and policies', body: () => barChart(b.item, { ...big, empty: 'No failing apps or policies reported.' }) },
    { title: 'Failures by device model', body: () => barChart(b.model, big) },
    { title: 'Failures by deployment profile', body: () => barChart(b.profile, big) },
    { title: 'Structural improvements (ranked)', body: () => h('ol', { class: 'pres-imp' }, (state.data.improvements ?? []).slice(0, 5).map(i => h('li', {}, h('strong', { text: i.structuralAction }), h('span', { class: 'muted', text: ` (${i.deployments} failed deployment(s))` })))) },
  ];
  const sel = deployments().find(d => d.id === state.selectedId);
  if (sel) list.push({ title: `Deployment: ${show(sel.deviceName)}`, body: () => h('div', { class: 'pres-detail' }, factGrid([['Status', sel.status], ['Phase', sel.phase], ['Flow', sel.flow], ['Error codes', sel.errorCodes?.join(', ') || null]]), (sel.findings ?? []).slice(0, 2).map(findingCard)) });
  return list;
}

function setPresentation(on) {
  state.presenting = on;
  document.body.classList.toggle('presenting', on);
  $('#presentation').classList.toggle('hidden', !on);
  $('#presentBtn').textContent = on ? 'Exit presentation' : 'Presentation mode';
  if (on) { state.slide = 0; $('#detailDialog').close(); renderPresentation(); }
  else { clear($('#presentation')); render(); }
}

function renderPresentation() {
  const host = clear($('#presentation'));
  if (!state.data?.hasData) { host.appendChild(h('div', { class: 'pres-slide' }, h('h2', { text: 'No data loaded' }), h('p', { text: 'Press Esc, then load data or Demo mode.' }))); return; }
  const list = slides();
  state.slide = Math.max(0, Math.min(state.slide, list.length - 1));
  const sl = list[state.slide];
  host.appendChild(h('div', { class: 'pres-slide' },
    h('div', { class: 'pres-top' }, h('h2', { text: sl.title }),
      h('span', { class: 'pres-meta', text: `${state.data.meta.mode === 'demo' ? 'Demo data · ' : ''}${state.boot.anonymize ? 'Anonymized · ' : ''}${state.slide + 1} / ${list.length}` })),
    h('div', { class: 'pres-body' }, sl.body()),
    h('div', { class: 'pres-nav' },
      h('button', { type: 'button', class: 'btn', disabled: state.slide === 0, on: { click: () => { state.slide--; renderPresentation(); } } }, '← Previous'),
      h('span', { class: 'muted', text: '←/→ or PgUp/PgDn to navigate · Esc to exit · A to anonymize' }),
      h('button', { type: 'button', class: 'btn', disabled: state.slide === list.length - 1, on: { click: () => { state.slide++; renderPresentation(); } } }, 'Next →'))));
}

function onKey(e) {
  const typing = ['INPUT', 'SELECT', 'TEXTAREA'].includes(document.activeElement?.tagName);
  if (typing || e.ctrlKey || e.metaKey || e.altKey) return;
  if (document.querySelector('dialog[open]') && !state.presenting) return;
  const k = e.key;
  if (k === 'p' || k === 'P') { setPresentation(!state.presenting); e.preventDefault(); return; }
  if (k === 'a' || k === 'A') { const t = $('#anonToggle'); t.checked = !t.checked; setAnonymize(t.checked).then(() => state.presenting && renderPresentation()); e.preventDefault(); return; }
  if (state.presenting) {
    const n = slides().length;
    if (['ArrowRight', 'PageDown', ' '].includes(k)) { state.slide = Math.min(n - 1, state.slide + 1); renderPresentation(); e.preventDefault(); }
    else if (['ArrowLeft', 'PageUp', 'Backspace'].includes(k)) { state.slide = Math.max(0, state.slide - 1); renderPresentation(); e.preventDefault(); }
    else if (k === 'Home') { state.slide = 0; renderPresentation(); e.preventDefault(); }
    else if (k === 'End') { state.slide = n - 1; renderPresentation(); e.preventDefault(); }
    else if (k === 'Escape') { setPresentation(false); e.preventDefault(); }
    else if (/^[1-9]$/.test(k)) { state.slide = Math.min(n - 1, Number(k) - 1); renderPresentation(); e.preventDefault(); }
    return;
  }
  const views = ['overview', 'deployments', 'improvements', 'diagnostics', 'sources'];
  if (/^[1-5]$/.test(k)) { setView(views[Number(k) - 1]); e.preventDefault(); }
}

boot();
