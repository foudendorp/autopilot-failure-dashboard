// Frontend filter tests (run with: node --test tests/js/filters.test.mjs).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { passesFilters, filterBreakdown } from '../../web/assets/filters.js';

const none = { flow: '', status: '', profile: '', model: '', search: '' };
// The regression example: failed deployment that started on 2026-11-03, eventDateTime unusable.
const example = { id: 'a', status: 'Failed', flow: 'User-driven (Entra join)', day: '2026-11-03', dayCandidates: ['2026-11-03'], profile: '', model: '' };

test('a failed deployment inside the date range is shown with default filters', () => {
  assert.equal(passesFilters(example, none, '2026-10-07', '2026-11-06'), true);
});

test('a row is shown when any of its dates is inside the range', () => {
  const row = { ...example, day: '2026-09-20', dayCandidates: ['2026-09-20', '2026-11-03'] };
  assert.equal(passesFilters(row, none, '2026-10-07', '2026-11-06'), true);
});

test('a row without any date is never hidden by the date filter', () => {
  const row = { ...example, day: null, dayCandidates: [] };
  assert.equal(passesFilters(row, none, '2026-10-07', '2026-11-06'), true);
});

test('a row entirely outside the range is hidden', () => {
  const row = { ...example, day: '2026-09-01', dayCandidates: ['2026-09-01'] };
  assert.equal(passesFilters(row, none, '2026-10-07', '2026-11-06'), false);
});

test('missing profile/model match the "Not available" option', () => {
  assert.equal(passesFilters(example, { ...none, profile: 'Not available', model: 'Not available' }, '', ''), true);
});

test('status filter Failed keeps the row, Success hides it', () => {
  assert.equal(passesFilters(example, { ...none, status: 'Failed' }, '', ''), true);
  assert.equal(passesFilters(example, { ...none, status: 'Success' }, '', ''), false);
});

test('breakdown reports which filter hides how many rows', () => {
  const rows = [example, { ...example, id: 'b', status: 'Success' }, { ...example, id: 'c', day: '2026-01-01', dayCandidates: ['2026-01-01'] }];
  const b = filterBreakdown(rows, { ...none, status: 'Failed' }, '2026-10-07', '2026-11-06');
  assert.equal(b.total, 3);
  assert.equal(b.shown, 1);
  assert.equal(b.hiddenBy.date, 1);
  assert.equal(b.hiddenBy.status, 1);
});
