// Safe DOM helpers. All Graph and log data is untrusted: it is only ever inserted as text
// (textContent / createTextNode) or as validated attributes. innerHTML is never used with data.
'use strict';

const SVG_NS = 'http://www.w3.org/2000/svg';
const BLOCKED_ATTR = /^on/i;

function applyAttrs(el, attrs) {
  if (!attrs) return el;
  for (const [key, value] of Object.entries(attrs)) {
    if (value === undefined || value === null || value === false) continue;
    if (key === 'class') el.setAttribute('class', String(value));
    else if (key === 'text') el.textContent = String(value);
    else if (key === 'dataset') Object.entries(value).forEach(([k, v]) => { el.dataset[k] = String(v); });
    else if (key === 'on') Object.entries(value).forEach(([evt, fn]) => el.addEventListener(evt, fn));
    else if (key === 'href') {
      const safe = safeUrl(value);
      if (safe) el.setAttribute('href', safe);
    }
    else if (key === 'style') throw new Error('Inline style attributes are not allowed (CSP).');
    else if (BLOCKED_ATTR.test(key)) throw new Error('Event handler attributes are not allowed.');
    else if (value === true) el.setAttribute(key, '');
    else el.setAttribute(key, String(value));
  }
  return el;
}

function appendChildren(el, children) {
  for (const child of children.flat(Infinity)) {
    if (child === null || child === undefined || child === false) continue;
    el.appendChild(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return el;
}

/** Create an HTML element: h('div', {class:'x'}, 'text', h('span', ...)). */
export function h(tag, attrs, ...children) {
  return appendChildren(applyAttrs(document.createElement(tag), attrs), children);
}

/** Create an SVG element. */
export function s(tag, attrs, ...children) {
  const el = document.createElementNS(SVG_NS, tag);
  if (attrs) {
    for (const [key, value] of Object.entries(attrs)) {
      if (value === undefined || value === null) continue;
      if (key === 'text') el.textContent = String(value);
      else if (key === 'class') el.setAttribute('class', String(value));
      else if (key === 'on') Object.entries(value).forEach(([evt, fn]) => el.addEventListener(evt, fn));
      else if (BLOCKED_ATTR.test(key) || key === 'href' || key === 'style') throw new Error(`SVG attribute ${key} not allowed.`);
      else el.setAttribute(key, String(value));
    }
  }
  return appendChildren(el, children);
}

/** Only allows documentation links on learn.microsoft.com and same-origin relative API/download paths. */
export function safeUrl(value) {
  const str = String(value ?? '');
  if (/^\/(api\/download\/[A-Za-z0-9_-]+)$/.test(str)) return str;
  try {
    const u = new URL(str);
    if (u.protocol === 'https:' && (u.hostname === 'learn.microsoft.com' || u.hostname === 'intune.microsoft.com' || u.hostname === 'entra.microsoft.com')) return u.href;
  } catch { /* not a URL */ }
  return null;
}

export function clear(el) { while (el.firstChild) el.removeChild(el.firstChild); return el; }

export function $(sel, root = document) { return root.querySelector(sel); }
export function $all(sel, root = document) { return Array.from(root.querySelectorAll(sel)); }

/** Text for missing values. Missing data is never treated as success or failure. */
export const NA = 'Not available';
export function show(v) { return (v === null || v === undefined || v === '') ? NA : String(v); }

export function fmtDate(iso, withTime = true) {
  if (!iso) return NA;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return NA;
  return withTime ? d.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }) : d.toLocaleDateString(undefined, { dateStyle: 'medium' });
}

export function fmtDuration(sec) {
  if (sec === null || sec === undefined || sec === '' || Number.isNaN(Number(sec))) return NA;
  const m = Math.round(Number(sec) / 60);
  if (m < 60) return `${m} min`;
  return `${Math.floor(m / 60)} h ${m % 60} min`;
}
