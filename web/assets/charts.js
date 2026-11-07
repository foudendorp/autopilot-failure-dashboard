// Minimal dependency-free SVG charts. Labels are set with textContent only.
'use strict';
import { h, s } from './dom.js';

const truncate = (t, n) => (t.length > n ? `${t.slice(0, n - 1)}…` : t);

/**
 * Horizontal bar chart.
 * data: [{ label, value, title? }], opts: { max: 8, onClick(label), empty: 'text', cssClass }
 */
export function barChart(data, opts = {}) {
  const max = opts.max ?? 8;
  const rows = data.slice(0, max);
  if (!rows.length) return h('p', { class: 'chart-empty', text: opts.empty ?? 'No failures in the current selection.' });
  const width = opts.width ?? 520, labelW = opts.labelWidth ?? 210, rowH = 28, pad = 6;
  const height = rows.length * rowH + pad * 2;
  const top = Math.max(...rows.map(r => r.value), 1);
  const svg = s('svg', { viewBox: `0 0 ${width} ${height}`, class: `chart bar-chart ${opts.cssClass ?? ''}`, role: 'img', 'aria-label': opts.ariaLabel ?? 'Bar chart' });
  rows.forEach((r, i) => {
    const y = pad + i * rowH;
    const barW = Math.max(2, ((width - labelW - 60) * r.value) / top);
    const g = s('g', { class: opts.onClick ? 'bar-row clickable' : 'bar-row', tabindex: opts.onClick ? 0 : null });
    g.appendChild(s('title', { text: `${r.title ?? r.label}: ${r.value}` }));
    g.appendChild(s('text', { x: labelW - 8, y: y + rowH / 2 + 4, 'text-anchor': 'end', class: 'bar-label', text: truncate(String(r.label), 30) }));
    g.appendChild(s('rect', { x: labelW, y: y + 5, width: barW, height: rowH - 10, rx: 3, class: `bar ${r.cls ?? opts.barClass ?? 'bar-fail'}` }));
    g.appendChild(s('text', { x: labelW + barW + 6, y: y + rowH / 2 + 4, class: 'bar-value', text: String(r.value) }));
    if (opts.onClick) {
      g.addEventListener('click', () => opts.onClick(r.label));
      g.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); opts.onClick(r.label); } });
    }
    svg.appendChild(g);
  });
  const wrap = h('div', { class: 'chart-wrap' }, svg);
  if (data.length > max) wrap.appendChild(h('p', { class: 'chart-more', text: `+ ${data.length - max} more` }));
  return wrap;
}

/**
 * Stacked daily columns. days: [{ day:'2026-10-01', success, failed, na, other }]
 */
export function dailyTrend(days) {
  if (!days.length) return h('p', { class: 'chart-empty', text: 'No deployments in the current selection.' });
  const width = 760, height = 260, left = 36, bottom = 34, top = 12, right = 8;
  const innerW = width - left - right, innerH = height - top - bottom;
  const maxV = Math.max(...days.map(d => d.success + d.failed + d.na + d.other), 1);
  const colW = innerW / days.length;
  const svg = s('svg', { viewBox: `0 0 ${width} ${height}`, class: 'chart trend-chart', role: 'img', 'aria-label': 'Deployments per day' });
  const ticks = niceTicks(maxV);
  ticks.forEach(t => {
    const y = top + innerH - (innerH * t) / ticks[ticks.length - 1];
    svg.appendChild(s('line', { x1: left, x2: width - right, y1: y, y2: y, class: 'grid' }));
    svg.appendChild(s('text', { x: left - 6, y: y + 4, 'text-anchor': 'end', class: 'axis', text: String(t) }));
  });
  const scaleMax = ticks[ticks.length - 1];
  days.forEach((d, i) => {
    let y = top + innerH;
    const x = left + i * colW + colW * 0.15;
    const w = Math.max(colW * 0.7, 1);
    const g = s('g', {});
    g.appendChild(s('title', { text: `${d.day}\nSuccess: ${d.success}\nFailed: ${d.failed}\nNot available: ${d.na}\nOther: ${d.other}` }));
    for (const [key, cls] of [['success', 'seg-success'], ['failed', 'seg-fail'], ['other', 'seg-other'], ['na', 'seg-na']]) {
      const v = d[key];
      if (!v) continue;
      const hgt = (innerH * v) / scaleMax;
      y -= hgt;
      g.appendChild(s('rect', { x, y, width: w, height: Math.max(hgt - 1, 0.5), class: cls }));
    }
    svg.appendChild(g);
    const every = Math.ceil(days.length / 10);
    if (i % every === 0) svg.appendChild(s('text', { x: x + w / 2, y: height - 12, 'text-anchor': 'middle', class: 'axis', text: d.day.slice(5) }));
  });
  const legend = h('div', { class: 'legend' },
    h('span', { class: 'lg lg-success' }, 'Success'), h('span', { class: 'lg lg-fail' }, 'Failed'),
    h('span', { class: 'lg lg-other' }, 'In progress / not attempted'), h('span', { class: 'lg lg-na' }, 'Not available'));
  return h('div', { class: 'chart-wrap' }, svg, legend);
}

function niceTicks(max) {
  const steps = [1, 2, 5, 10, 20, 25, 50, 100, 200, 500];
  const step = steps.find(st => max / st <= 5) ?? Math.ceil(max / 5);
  const out = [];
  for (let v = 0; v <= max + step - 1; v += step) out.push(v);
  if (out[out.length - 1] < max) out.push(out[out.length - 1] + step);
  return out;
}
