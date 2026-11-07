// Pure filter logic (no DOM), shared by the dashboard and the node tests in tests/js.
'use strict';

const NA = 'Not available';

function inRange(row, from, to) {
  // A row passes when ANY of its known dates is inside [from, to]. Rows without a date are never
  // hidden by the date filter (they show as "Not available").
  const days = (row.dayCandidates && row.dayCandidates.length) ? row.dayCandidates : (row.day ? [row.day] : []);
  if (!days.length) return true;
  return days.some(day => (!from || day >= from) && (!to || day <= to));
}

function matchesSearch(d, q) {
  if (!q) return true;
  const hay = [d.deviceName, d.serial, d.upn, d.model, d.manufacturer, d.profile, d.phase, d.flow, d.status, d.enrollmentFailure, d.id,
    ...(d.errorCodes ?? []), ...(d.failedItems ?? []).map(i => i.name), ...(d.findings ?? []).map(x => x.ruleId)].join(' ').toLowerCase();
  return hay.includes(q);
}

/** Each check by name, so the diagnostics view can say which filter hides a row. */
function checks(d, f, from, to) {
  return {
    date: inRange(d, from, to),
    flow: !f.flow || d.flow === f.flow,
    status: !f.status || d.status === f.status,
    profile: !f.profile || (d.profile || NA) === f.profile,
    model: !f.model || (d.model || NA) === f.model,
    search: matchesSearch(d, (f.search ?? '').trim().toLowerCase()),
  };
}

export function passesFilters(d, f, from, to) {
  return Object.values(checks(d, f, from, to)).every(Boolean);
}

/** Counts how many rows each filter hides (a row hidden by two filters counts for both). */
export function filterBreakdown(rows, f, from, to) {
  const hiddenBy = { date: 0, flow: 0, status: 0, profile: 0, model: 0, search: 0 };
  let shown = 0;
  for (const d of rows) {
    const c = checks(d, f, from, to);
    if (Object.values(c).every(Boolean)) { shown++; continue; }
    for (const [k, ok] of Object.entries(c)) if (!ok) hiddenBy[k]++;
  }
  return { total: rows.length, shown, hiddenBy };
}
