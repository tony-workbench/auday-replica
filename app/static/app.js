"use strict";
// Auday Replica front end: vanilla JS, no build step. Layout follows Auday's iPhone app
// (docs/AUDAY_UI.md): Days / Chat / Search in a floating tab bar, pages pushed on top.

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const view = $("#view");
const state = {
  today: null, dates: [], date: null, memTab: "review", chat: [], conversation: null, chatBusy: null,
  rec: null, settings: null, status: null, scope: { kind: "all" }, searchMode: "hybrid", lastQuery: "",
};

const KIND = { transcript: "Transcript", highlight: "Highlight", summary: "Hour summary", reflection: "Daily Reflection", memory: "Memory" };
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const MONTHS_LONG = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

const ICON = {
  logo: `<svg class="logo" viewBox="0 0 24 28" aria-hidden="true"><path d="M3 10v9M8.5 4v22M14 7v13M19.5 11v8"/></svg>`,
  watch: `<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="6" y="5.5" width="12" height="13" rx="3.5"/><path d="M9 5.5 9.6 2.5h4.8L15 5.5M9 18.5l.6 3h4.8l.6-3M18 10.5h1"/></svg>`,
  more: `<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="5.5" cy="12" r="1.2" fill="currentColor"/><circle cx="12" cy="12" r="1.2" fill="currentColor"/><circle cx="18.5" cy="12" r="1.2" fill="currentColor"/></svg>`,
  back: `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 5 8 12l7 7"/></svg>`,
  close: `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6 6 18"/></svg>`,
  share: `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 15V3M8 7l4-4 4 4M6 11v8a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2v-8"/></svg>`,
  calendar: `<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="4" y="5" width="16" height="15" rx="3"/><path d="M4 10h16M9 3v4M15 3v4"/></svg>`,
  stack: `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m12 4 8 4-8 4-8-4z"/><path d="m4 12 8 4 8-4M4 16l8 4 8-4"/></svg>`,
  clock: `<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="8"/><path d="M12 8v4l3 2"/></svg>`,
  compose: `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 20h8M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/></svg>`,
  send: `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 19V5M6 11l6-6 6 6"/></svg>`,
  stop: `<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="7" y="7" width="10" height="10" rx="2" fill="currentColor"/></svg>`,
  search: `<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="11" cy="11" r="6"/><path d="m16 16 4 4"/></svg>`,
  sync: `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 12a8 8 0 0 1-14 5.3M4 12a8 8 0 0 1 14-5.3"/><path d="M18 3v4h-4M6 21v-4h4"/></svg>`,
  hand: `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 11V5.5a1.5 1.5 0 0 1 3 0V11m0-1.5a1.5 1.5 0 0 1 3 0V11m0-.5a1.5 1.5 0 0 1 3 0V15a6 6 0 0 1-6 6h-.5a6 6 0 0 1-5-2.7L4 14.5a1.5 1.5 0 0 1 2.4-1.8L9 15"/><path d="M6 6.5a4.5 4.5 0 0 1 9 0" opacity=".5"/></svg>`,
  watchBig: `<svg viewBox="0 0 26 30" aria-hidden="true"><path d="M8.5 5 9.5 1.5h7l1 3.5M8.5 25l1 3.5h7l1-3.5" stroke-width="1.8"/><rect x="4" y="5" width="18" height="20" rx="5.5" fill="currentColor" stroke="none"/><rect x="7" y="8" width="12" height="14" rx="3" fill="var(--bg)" stroke="none" opacity=".35"/><path d="M22.5 12.5v3" stroke-width="2"/></svg>`,
};

// ---------- helpers ----------
function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}
function h(html) { const t = document.createElement("template"); t.innerHTML = html.trim(); return t.content.firstElementChild; }
function toast(text, ms = 2600) {
  const el = $("#toast"); el.textContent = text; el.hidden = false;
  clearTimeout(toast.t); toast.t = setTimeout(() => (el.hidden = true), ms);
}
async function api(path, opts = {}) {
  const init = { method: opts.method || (opts.body !== undefined ? "POST" : "GET"), headers: {}, signal: opts.signal };
  if (opts.body instanceof Blob) { init.body = opts.body; }
  else if (opts.body !== undefined) { init.body = JSON.stringify(opts.body); init.headers["Content-Type"] = "application/json"; }
  const res = await fetch("/api/" + path, init);
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || res.statusText);
  return data;
}
function isoLocal(d = new Date()) {
  const p = n => String(n).padStart(2, "0"), off = -d.getTimezoneOffset();
  const sign = off >= 0 ? "+" : "-", a = Math.abs(off);
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}${sign}${p(a / 60 | 0)}:${p(a % 60)}`;
}
const ymd = d => isoLocal(d).slice(0, 10);
const dayDate = s => new Date(s + "T12:00:00");
function addDays(s, n) { const d = dayDate(s); d.setDate(d.getDate() + n); return ymd(d); }
const hm = s => (s || "").slice(11, 16);
const hms = s => (s || "").slice(11, 19);
const hh = n => String(n % 24).padStart(2, "0") + ":00";
function fmtDur(sec) {
  sec = Math.round(sec || 0);
  if (sec < 60) return `${sec}s`;
  if (sec < 3600) return `${Math.round(sec / 60)}m`;
  return `${Math.floor(sec / 3600)}h ${Math.round(sec % 3600 / 60)}m`;
}
// "Oct 26, 16:07" from any ISO time, shown in this browser's time zone.
function fmtWhen(s, withTime = true) {
  if (!s) return "";
  const d = new Date(s); if (isNaN(d)) return s;
  const p = n => String(n).padStart(2, "0");
  return `${MONTHS[d.getMonth()]} ${d.getDate()}${withTime ? `, ${p(d.getHours())}:${p(d.getMinutes())}` : ""}`;
}
function fmtDay(s) { const d = dayDate(s); return `${MONTHS[d.getMonth()]} ${d.getDate()}`; }
function speakerLabel(sp) { return sp === "user" ? "Me" : sp === "unknown" || !sp ? "Other" : sp; }
// Voiceprint labels as Auday shows them: Me = the owner, Me* = owner plus possibly others.
function whoLabel(seg) {
  if (seg.owner === "Me") return ["Me", "me"];
  if (seg.owner === "Me*") return ["Me*", "me mixed"];
  return [speakerLabel(seg.speaker), seg.speaker === "user" && !("owner" in seg) ? "me" : ""];
}
function densityLabel(d) { return d == null ? null : d < 34 ? "Low information" : d < 67 ? "Medium information" : "High information"; }
const plural = (n, one, many = one + "s") => `${n} ${n === 1 ? one : many}`;
function store(key, value) {
  try { if (value === undefined) return JSON.parse(localStorage.getItem(key) || "null"); localStorage.setItem(key, JSON.stringify(value)); }
  catch (e) { return null; }
}
const bindOpen = root => $$("[data-open]", root).forEach(el => el.onclick = e => { e.preventDefault(); e.stopPropagation(); openRecord(el.dataset.open); });

function topbar(left, title, right) {
  return `<header class="topbar"><div class="side">${left || ""}</div><div class="title">${title || ""}</div><div class="side right">${right || ""}</div></header>`;
}
const backBtn = (href = "#/days") => `<a class="round plain" href="${href}" data-back aria-label="Back">${ICON.back}</a>`;
function wireBack(root) {
  $$("[data-back]", root).forEach(a => a.onclick = e => {
    if (history.length > 1 && state.cameFromApp) { e.preventDefault(); history.back(); }
  });
}

// ---------- routing ----------
// #/days[/date]  #/hour/date/hour  #/reflection/date  #/chat  #/search  #/memory  #/settings[/archive]
function route() {
  const [name = "days", ...args] = location.hash.replace(/^#\/?/, "").split("/").filter(Boolean);
  return { name, args };
}
async function render() {
  closeMenu();
  const { name, args } = route();
  const tab = ["days", "chat", "search"].includes(name) ? name : null;
  $("#pillbar").hidden = !tab;
  $$("#pillbar a").forEach(a => a.classList.toggle("active", a.dataset.tab === tab));
  view.className = tab ? "" : "sub";
  const pages = { days: renderDays, hour: renderHour, reflection: renderReflection, chat: renderChat, search: renderSearch, memory: renderMemory, settings: renderSettings };
  try { await (pages[name] || renderDays)(...args); }
  catch (e) { view.innerHTML = topbar(backBtn(), "") + `<div class="empty">Something went wrong: ${esc(e.message)}</div>`; }
}
let lastHash = null;
window.addEventListener("hashchange", () => {
  state.cameFromApp = true;
  const scroll = route().name !== (lastHash || "").split("/")[1];
  lastHash = location.hash;
  render().then(() => scroll && window.scrollTo(0, 0));
});
const nav = hash => { if (location.hash === hash) render(); else location.hash = hash; };

// ---------- "…" menu ----------
function openMenu(anchor, items) {
  const menu = $("#menu");
  menu.innerHTML = items.map((it, i) => it === "-" ? "<hr>" : `<button data-i="${i}">${esc(it[0])}${it[2] ? `<span class="faint">${esc(it[2])}</span>` : ""}</button>`).join("");
  $$("button", menu).forEach(b => b.onclick = () => { closeMenu(); items[b.dataset.i][1](); });
  const r = anchor.getBoundingClientRect();
  menu.style.top = r.bottom + 8 + "px";
  menu.style.right = Math.max(12, innerWidth - r.right) + "px";
  menu.hidden = false;
  setTimeout(() => document.addEventListener("click", closeMenu, { once: true }), 0);
}
function closeMenu() { $("#menu").hidden = true; }
function mainMenu(anchor) {
  const reviews = (state.status && state.status.reviewCount) || 0;
  openMenu(anchor, [
    ["Your memory", () => nav("#/memory"), reviews ? `${reviews} to review` : ""],
    ["Settings", () => nav("#/settings")],
    ["Your archive", () => nav("#/settings/archive")],
    "-",
    ["Export library.json", exportLibrary],
  ]);
}

// ---------- sheet ----------
function openSheet(html, onClose) {
  $("#sheetBody").innerHTML = html; $("#sheet").hidden = false; $("#sheetBackdrop").hidden = false;
  $("#sheet").scrollTop = 0;
  state.sheetClose = onClose || null;
  bindOpen($("#sheetBody"));
  $$("[data-close]", $("#sheetBody")).forEach(b => b.onclick = closeSheet);
}
function closeSheet() {
  if ($("#sheet").hidden) return;
  $("#sheet").hidden = true; $("#sheetBackdrop").hidden = true;
  $$("audio", $("#sheetBody")).forEach(a => a.pause());
  const fn = state.sheetClose; state.sheetClose = null; fn && fn();
}
$("#sheetBackdrop").onclick = closeSheet;
document.addEventListener("keydown", e => e.key === "Escape" && (closeSheet(), closeMenu()));
const sheetHead = (title, right) => `<div class="sheethead"><div class="title">${esc(title)}</div>${right || `<button class="round" data-close aria-label="Close">${ICON.close}</button>`}</div>`;

async function openRecord(id) {
  if (id.startsWith("mem_")) return openMemory(id);
  let r;
  try { r = await api("record/" + encodeURIComponent(id)); } catch (e) { return toast("Source not found: " + id); }
  const offset = r.audioOffset || 0;
  const audio = r.audioAssetID ? `<audio controls preload="metadata" src="/api/audio/${esc(r.audioAssetID)}#t=${offset}"></audio>` : "";
  const segs = (r.segments || []).map(s => `<div class="line"><span class="who ${whoLabel(s)[1]}">${esc(whoLabel(s)[0])}</span><span>${esc(s.text)}</span>
      ${r.audioAssetID ? `<button class="play" data-seek="${s.start || 0}" aria-label="Play">▶</button>` : "<span></span>"}</div>`).join("");
  const body = segs ? `<div class="lines">${segs}</div>` : `<p class="prose">${esc(r.text)}</p>`;
  const threads = (r.threads || []).map(t => `<p>· ${esc(t.text)} ${(t.source_ids || []).map(s => `<button class="link small" data-open="${esc(s)}">${esc(s)}</button>`).join(" ")}</p>`).join("");
  const date = (r.start || "").slice(0, 10), hour = +(r.start || "").slice(11, 13);
  openSheet(`${sheetHead(KIND[r.kind] || r.kind)}
    <div class="faint">${esc(fmtWhen(r.start))}${r.end ? " – " + esc(hm(r.end)) : ""}</div>
    ${r.title ? `<h2 style="margin-top:8px">${esc(r.title)}</h2>` : ""}
    ${["summary", "reflection", "highlight"].includes(r.kind) ? `<p class="faint">Written by AI. Check details against the transcript.</p>` : ""}
    ${audio}${body}${threads}
    ${r.reason ? `<p class="muted">Why it matters: ${esc(r.reason)}</p>` : ""}
    ${r.kind !== "reflection" && date ? `<p><a class="link" href="#/hour/${date}/${hour}" data-close>Open this hour ↗</a></p>` : ""}
    <dl class="kv"><dt>ID</dt><dd>${esc(r.id)}</dd>
      ${(r.sourceIDs || []).length ? `<dt>Sources</dt><dd>${r.sourceIDs.map(s => `<button class="link small" data-open="${esc(s)}">${esc(s)}</button>`).join("<br>")}</dd>` : ""}
      ${r.revision ? `<dt>Revision</dt><dd>${r.revision}</dd>` : ""}${r.language ? `<dt>Language</dt><dd>${esc(r.language)}</dd>` : ""}</dl>`);
  const player = $("#sheetBody audio");
  $$("[data-seek]", $("#sheetBody")).forEach(b => b.onclick = () => { player.currentTime = +b.dataset.seek; player.play(); });
}

async function openMemory(id) {
  const [{ memories }, hist] = await Promise.all([api("memories"), api(`memories/${id}/history`)]);
  const m = memories.find(x => x.id === id);
  if (!m) return toast("Memory not found: " + id);
  const versions = hist.versions.map(v => `<div class="line" style="grid-template-columns:74px 1fr"><span class="who">${esc(v.op)}</span><span>${esc(v.content)} <span class="faint">${esc(v.status)} · ${esc(fmtWhen(v.changed_at))}${v.reason ? " · " + esc(v.reason) : ""}</span></span></div>`).join("");
  openSheet(`${sheetHead("Memory")}<div id="memSheet">${memoryItem(m)}</div>
    <div class="section-head"><h2>Evidence</h2></div>
    ${m.evidence.map(e => `<div class="card"><div>“${esc(e.quote)}”</div><button class="link small" data-open="${esc(e.record_id)}">${esc(e.record_id)}</button></div>`).join("")
      || `<p class="faint">Sources: ${m.sourceIDs.map(s => `<button class="link small" data-open="${esc(s)}">${esc(s)}</button>`).join(", ") || "none"}</p>`}
    <div class="section-head"><h2>History</h2></div><div class="lines">${versions}</div>`);
  bindMemoryActions($("#memSheet"), () => openMemory(id));
}

// ---------- DAYS ----------
async function loadDates() {
  const d = await api("dates"); state.today = d.today; state.dates = d.dates;
  if (!state.date) state.date = d.dates.includes(d.today) || !d.dates.length ? d.today : d.dates[0];
}
function daysHeader() {
  const live = !!state.rec;
  return topbar(`<div class="brand">${ICON.logo}Auday<span class="pulse" id="pulse"></span></div>`, "",
    `<button class="round ${live ? "live" : ""}" id="watchBtn" aria-label="Your Watch">${ICON.watch}<span class="dot" id="watchDot" ${live ? "" : "hidden"}></span></button>
     <button class="round" id="moreBtn" aria-label="More">${ICON.more}<span class="dot" id="moreDot" hidden></span></button>`);
}
function wireDaysHeader() {
  $("#watchBtn").onclick = openWatch;
  $("#moreBtn").onclick = e => { e.stopPropagation(); mainMenu(e.currentTarget); };
  paintStatus();
}

async function renderDays(date) {
  if (!state.today) await loadDates();
  if (date) state.date = date;
  const day = await api("day?date=" + state.date);
  const hours = day.hours, byHour = Object.fromEntries(hours.map(x => [x.hour, x]));
  const total = hours.reduce((n, x) => n + (x.recordedSeconds || 0), 0);
  const d = dayDate(state.date), isToday = state.date === state.today;
  view.innerHTML = daysHeader() + `
    <section class="datehead"><div class="big"><div class="num">${d.getDate()}</div>
      <div><div class="wd">${WEEKDAYS[d.getDay()]}</div><div class="my">${MONTHS_LONG[d.getMonth()]} ${d.getFullYear()}</div></div></div>
      <button class="round" id="calBtn" aria-label="Choose a day">${ICON.calendar}</button></section>
    <div class="dayline">${isToday ? "Today" : WEEKDAYS[d.getDay()].slice(0, 3)} — ${fmtDur(total)}</div>
    ${weekStrip()}
    ${dayBars(byHour)}
    <div id="reflSlot"></div>
    <div class="section-head"><h2>The day's hours</h2><span class="count">${hours.filter(x => x.transcripts.length).length} captured</span></div>
    <div class="hours" id="hours"></div>
    <p class="footnote">Your recordings and transcripts stay on this Mac. Optional services connect directly to the provider you choose.</p>`;
  wireDaysHeader();
  $("#calBtn").onclick = () => pickDay(state.date, date => nav("#/days/" + date));
  $$(".week [data-date]").forEach(b => b.onclick = () => nav("#/days/" + b.dataset.date));
  $$(".daybars [data-hour]").forEach(b => b.onclick = () => nav(`#/hour/${state.date}/${b.dataset.hour}`));
  $("#reflSlot").append(reflectionTeaser(day.reflection, hours));
  const list = $("#hours");
  if (!hours.length) {
    list.innerHTML = `<div class="empty">No capture ${isToday ? "yet today" : "on this day"}.<br>
      <button class="btn" id="startHere" style="margin-top:14px">Open Your Watch</button></div>`;
    $("#startHere").onclick = openWatch;
    return;
  }
  const first = hours[0].hour, last = isToday ? Math.max(hours[hours.length - 1].hour, new Date().getHours()) : hours[hours.length - 1].hour;
  for (let hr = first; hr <= last; hr++) list.append(hourRow(byHour[hr] || { hour: hr, transcripts: [], highlights: [], marks: [] }));
}

function weekStrip() {
  const d = dayDate(state.date), monday = addDays(state.date, -((d.getDay() + 6) % 7));
  const days = Array.from({ length: 7 }, (_, i) => addDays(monday, i));
  return `<div class="week">${days.map(s => {
    const cls = [s === state.date && "sel", s === state.today && "today", state.dates.includes(s) && "has", s > state.today && "future"].filter(Boolean).join(" ");
    return `<button class="${cls}" data-date="${s}" aria-label="${s}"><span class="wl">${WEEKDAYS[dayDate(s).getDay()][0]}</span><span class="wn">${dayDate(s).getDate()}</span></button>`;
  }).join("")}</div>`;
}

// One bar per hour: height = the information density from the hour's summary, or, without one,
// how much text was transcribed. Hours still processing are hatched; no capture is a thin line.
function dayBars(byHour) {
  const all = Object.values(byHour);
  const words = x => x.transcripts.reduce((n, t) => n + (t.text || "").length, 0);
  const most = Math.max(1, ...all.map(words));
  const bars = Array.from({ length: 24 }, (_, hr) => {
    const x = byHour[hr];
    if (!x || (!x.transcripts.length && !x.quiet && !x.pendingAudio)) return `<span class="bar empty" title="${hh(hr)} · no capture"></span>`;
    if (x.quiet) return `<button class="bar quiet" data-hour="${hr}" title="${hh(hr)} · quiet"></button>`;
    const density = x.summary && x.summary.informationDensity != null ? x.summary.informationDensity : null;
    const busy = (!x.summary && ["pending", "running", null, undefined].includes(x.state)) || (x.pendingAudio && !x.transcripts.length);
    const height = density != null ? density : Math.round(100 * words(x) / most);
    const tip = `${hh(hr)} · ${density != null ? "information density " + density : busy ? "processing" : plural(x.transcripts.length, "transcript")}`;
    return `<button class="bar ${busy ? "busy" : ""}" data-hour="${hr}" title="${esc(tip)}" style="--h:${busy ? 100 : Math.max(8, height)}%"></button>`;
  }).join("");
  return `<div class="daybars"><div class="bars">${bars}</div><div class="axis"><span>0</span><span>6</span><span>12</span><span>18</span><span>24</span></div></div>`;
}

function reflectionTeaser(r, hours) {
  if (r) {
    const st = r.stats || {};
    const recorded = hours.reduce((n, x) => n + (x.recordedSeconds || 0), 0);
    const nHl = st.highlights ?? hours.reduce((n, x) => n + x.highlights.length, 0);
    const el = h(`<a class="refl-card" href="#/reflection/${state.date}">
      <canvas width="640" height="230" aria-hidden="true"></canvas>
      <div class="body"><div class="eyebrow">Daily Reflection</div>
        <div class="cover clamp2">${esc(r.title)}</div>
        <div class="meta"><span>${recorded ? fmtDur(recorded) + " recorded · " : ""}${plural(nHl, "Highlight")}</span><span class="arrow">↗</span></div></div></a>`);
    drawDither($("canvas", el), (r.portrait && r.portrait.seed) || hashSeed(r.id));
    return el;
  }
  if (!hours.some(x => x.summary)) return h(`<div></div>`);
  const at = (state.settings && state.settings.reflection_time) || "";
  const el = h(`<div class="refl-empty"><div class="eyebrow">Daily Reflection</div>
    <p class="muted" style="margin:6px 0 12px">Your reflection is written after ${esc(at)} each day.</p></div>`);
  return el;   // written once a day after the Reflection time; unlike Auday, no "Generate now" button
}
function hashSeed(s) { let x = 7n; for (const c of String(s)) x = (x * 131n + BigInt(c.charCodeAt(0))) % (1n << 60n); return x.toString(); }

function hourRow(x) {
  const hasText = x.transcripts.length > 0;
  const dur = x.recordedSeconds ? fmtDur(x.recordedSeconds) : "";
  if (!hasText && x.quiet) {
    return h(`<a class="hourrow quiet" href="#/hour/${state.date}/${x.hour}"><div class="h1"><span class="t">${hh(x.hour)}</span><span class="st">QUIET</span><span class="dur">${dur}</span></div>
      <div class="note">A quiet hour.</div></a>`);
  }
  if (!hasText && x.pendingAudio) {
    return h(`<a class="hourrow" href="#/hour/${state.date}/${x.hour}"><div class="h1"><span class="t">${hh(x.hour)}</span><span class="st pending">WAITING</span><span class="dur">${dur}</span></div>
      <div class="note muted">Audio saved, waiting for transcription.</div></a>`);
  }
  if (!hasText) {
    const marks = x.marks.length ? ` · ${plural(x.marks.length, "mark")}` : "";
    return h(`<div class="hourrow nocap"><div class="h1"><span class="t">${hh(x.hour)}</span><span class="st">NO CAPTURE${marks}</span><span class="dur">${dur}</span></div></div>`);
  }
  const s = x.summary;
  const st = s ? ["CAPTURED", "captured"] : ({ failed: ["AI FAILED", "failed"], running: ["PROCESSING", "pending"] }[x.state] || ["CAPTURED", "captured"]);
  const note = s ? s.title : (x.transcripts[0].text || "").slice(0, 160);
  const bits = [];
  if (s && densityLabel(s.informationDensity)) bits.push(densityLabel(s.informationDensity));
  else if (!s) bits.push(x.state === "failed" ? "Could not summarize" : "Waiting for summary");
  if (x.highlights.length) bits.push(`✦ ${plural(x.highlights.length, "highlight")}`);
  if (x.marks.length) bits.push(plural(x.marks.length, "mark"));
  return h(`<a class="hourrow" href="#/hour/${state.date}/${x.hour}"><div class="h1"><span class="t">${hh(x.hour)}</span><span class="st ${st[1]}">${st[0]}</span><span class="dur">${dur}</span></div>
    <div class="note ${s ? "" : "muted"} clamp2">${esc(note)}</div>
    <div class="info"><span>${bits.map(esc).join(" · ")}</span><span class="arrow">↗</span></div></a>`);
}

// Cover artwork in Auday's "dither" style: seeded smooth noise, 1-bit ordered (Bayer) dithering.
function drawDither(canvas, seed) {
  if (!canvas.isConnected) return requestAnimationFrame(() => drawDither(canvas, seed));   // wait until it is in the page, so its CSS colour is known
  const ctx = canvas.getContext("2d"), w = canvas.width, hgt = canvas.height, px = Math.max(4, Math.round(w / 150));
  let x = BigInt(seed) || 1n;
  const rand = () => { x ^= x << 13n; x ^= x >> 7n; x ^= x << 17n; x &= (1n << 64n) - 1n; return Number(x % 10000n) / 10000; };
  const waves = Array.from({ length: 4 }, () => [rand() * 0.04 + 0.006, rand() * 0.05 + 0.008, rand() * 6.28, rand()]);
  const bayer = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]];
  const ink = getComputedStyle(canvas).color;
  ctx.clearRect(0, 0, w, hgt); ctx.fillStyle = ink;
  for (let j = 0; j < hgt / px; j++) for (let i = 0; i < w / px; i++) {
    let v = 0, total = 0;
    for (const [fx, fy, ph, amp] of waves) { v += (amp + 0.3) * Math.sin(i * fx * px + j * fy * px + ph); total += amp + 0.3; }
    v = 0.5 + 0.5 * v / total;
    v = v * v * (3 - 2 * v);                        // smoothstep: stronger light and dark areas
    if (v > (bayer[j % 4][i % 4] + 0.5) / 16) ctx.fillRect(i * px, j * px, px - 1, px - 1);
  }
}

// The day at a glance, like Auday's portrait: a cell per hour; filled when summarized, dots for
// Highlights, a warm edge for high stress, a ring for marks.
function portraitGrid(p) {
  const cells = p.hours.map(x => {
    const cls = ["cell", x.hasSummary ? "on" : "", x.bodyContextKinds.includes("stressElevated") ? "stress" : "", x.markCount ? "mark" : ""].join(" ");
    const tip = `${x.hourStart.slice(11, 16)} · ${x.highlightCount} Highlights${x.bodyContextLabels.length ? " · " + x.bodyContextLabels.join(", ") : ""}`;
    return `<span class="${cls}" title="${esc(tip)}">${"•".repeat(Math.min(3, x.highlightCount))}</span>`;
  }).join("");
  return `<div class="portrait">${cells}</div>`;
}

// ---------- HOUR ("Open this hour") ----------
async function renderHour(date, hourStr) {
  if (!state.today) await loadDates();
  state.date = date;
  const hour = +hourStr;
  const day = await api("day?date=" + date);
  const x = day.hours.find(y => y.hour === hour) || { hour, transcripts: [], highlights: [], marks: [], summary: null };
  const s = x.summary;
  const notes = s && s.pipeline === "auday" ? `<a class="round plain" href="/api/notes?date=${date}&hour=${hour}" target="_blank" rel="noopener" aria-label="Export Notes" title="Export Notes">${ICON.share}</a>` : "";
  const status = x.transcripts.length ? "Captured" : x.quiet ? "Quiet" : x.pendingAudio ? "Waiting for transcription" : "No capture";
  view.innerHTML = topbar(backBtn("#/days/" + date), `${hh(hour)} – ${hh(hour + 1)}`, notes) + `
    <div class="eyebrow" style="margin-top:8px">${esc(fmtDay(date))} · ${esc(status)}${x.recordedSeconds ? ` · <span style="text-transform:none">${fmtDur(x.recordedSeconds)}</span>` : ""}</div>
    ${s ? `<h1 class="serif">${esc(s.title)}</h1><p class="prose">${esc(s.text)}</p>`
      : `<h1 class="serif">${x.quiet ? "A quiet hour." : x.transcripts.length ? "Not summarized yet." : "Nothing captured."}</h1>`}
    ${s ? `<div class="chips">${densityLabel(s.informationDensity) ? `<span class="chip">${densityLabel(s.informationDensity)}</span>` : ""}
      ${x.highlights.length ? `<span class="chip">✦ ${plural(x.highlights.length, "highlight")}</span>` : ""}${x.marks.length ? `<span class="chip accent">${plural(x.marks.length, "mark")}</span>` : ""}</div>` : ""}
    ${x.error ? `<details class="card" style="margin-top:14px"><summary style="color:var(--bad)">The AI's answer was incomplete. The transcript is kept; you can summarize again. ▾</summary><p class="faint">${esc(x.error.slice(0, 300))}</p></details>` : ""}
    ${x.transcripts.some(t => t.audioAssetID) ? hourPlayer(date, hour) : ""}
    ${s && (s.attentionPoints || []).length ? `<div class="section-head"><h2>Worth noting</h2></div><ul class="attention">${s.attentionPoints.map(a => `<li>${esc(a)}</li>`).join("")}</ul>` : ""}
    ${s && (s.memoryPoints || []).length ? `<div class="section-head"><h2>Memory candidates</h2><span class="count">for review</span></div>
      <div class="chips">${s.memoryPoints.map(m => `<span class="chip ${m.stable ? "" : "info"}" title="${m.stable ? "Stable" : "May change"}">${esc(m.text)}</span>`).join("")}</div>` : ""}
    ${x.highlights.length ? `<div class="section-head"><h2>Highlights</h2><span class="count">${plural(x.highlights.length, "highlight")}</span></div><div id="hourHl"></div>` : ""}
    ${x.marks.length ? `<div class="section-head"><h2>Marks</h2></div><p class="muted">${x.marks.map(m => esc(hms(m.start)) + (m.note ? " — " + esc(m.note) : "")).join(" · ")}</p>` : ""}
    ${x.transcripts.length ? `<div class="section-head"><h2>Transcript</h2><span class="count">${plural(x.transcripts.length, "piece")}</span></div>
      <div class="lines">${x.transcripts.map(t => (t.segments || [{ speaker: "unknown", text: t.text }]).map(seg =>
        `<div class="line"><span class="who ${whoLabel(seg)[1]}">${hm(t.start)} ${esc(whoLabel(seg)[0])}</span><span>${esc(seg.text)}</span>
         <button class="play" data-open="${esc(t.id)}" aria-label="Open">▶</button></div>`).join("")).join("")}</div>` : ""}
    ${x.transcripts.length ? `<div class="refl-foot"><p class="faint">${s ? `Summary revision ${s.revision || 1}. Summarizing again replaces the summary and Highlights of this hour.` : "The hour is summarized automatically after it ends."}</p>
      <button class="btn" id="processHour">${s ? "Summarize again" : "Summarize now"}</button></div>` : ""}`;
  wireBack(view);
  const box = $("#hourHl");
  if (box) x.highlights.forEach(hl => box.append(highlightCard(hl, false)));
  bindOpen(view);
  wirePlayer(view);
  if ($("#processHour")) $("#processHour").onclick = async () => { await api("hour", { body: { date, hour } }); toast(`Summarizing ${hh(hour)}…`); };
}

// Like Auday's "Saved audio 13:00 – 14:00" bar: the hour's recording, ±15 s, playback speed.
function hourPlayer(date, hour) {
  return `<div class="player"><div class="row spread"><div><b>Saved audio</b><div class="faint">${hh(hour)} – ${hh(hour + 1)}</div></div>
    <div class="row"><button class="btn small ghost" data-skip="-15" aria-label="Back 15 seconds">−15</button>
    <button class="btn small ghost" data-skip="15" aria-label="Forward 15 seconds">+15</button>
    <button class="btn small ghost" data-rate>1×</button></div></div>
    <audio controls preload="none" src="/api/hour-audio?date=${encodeURIComponent(date)}&hour=${hour}"></audio></div>`;
}
function wirePlayer(root) {
  const audio = $(".player audio", root);
  if (!audio) return;
  $$("[data-skip]", root).forEach(b => b.onclick = () => { audio.currentTime = Math.max(0, audio.currentTime + Number(b.dataset.skip)); });
  const rate = $("[data-rate]", root);
  rate.onclick = () => { const next = { 1: 1.5, 1.5: 2, 2: 1 }[audio.playbackRate] || 1; audio.playbackRate = next; rate.textContent = next + "×"; };
}

// A Highlight as on Auday's Reflection page: time range, serif title, one line of reading,
// chips (Conversation, place, body signals), and "Open this hour".
function highlightCard(x, withHourLink = true) {
  const auday = x.pipeline === "auday";
  const chips = [];
  if (auday) chips.push(`<span class="chip">Conversation</span>`);
  (x.signals || []).forEach(c => chips.push(`<span class="chip ${c.alert ? "alert" : ""}">${esc(c.label)}</span>`));
  if (x.marked) chips.push(`<span class="chip accent">Marked</span>`);
  const date = (x.start || "").slice(0, 10), hour = +(x.start || "").slice(11, 13);
  const el = h(`<div class="hlcard" role="button" tabindex="0">
    <div class="when">✦ ${esc(hms(x.start))}${x.end ? "–" + esc(hms(x.end)) : ""}</div>
    <div class="htitle">${esc(x.title)}</div>
    <div class="why clamp1">${esc(auday ? x.reason || x.text : "“" + x.text + "”")}</div>
    ${chips.length ? `<div class="chips">${chips.join("")}</div>` : ""}
    ${auday && (x.text || (x.attentionPoints || []).length) ? `<details><summary>Full reading ▾</summary><p>${esc(x.text)}</p>
      ${(x.attentionPoints || []).length ? `<ul class="attention">${x.attentionPoints.map(a => `<li>${esc(a)}</li>`).join("")}</ul>` : ""}
      ${x.mayContinueBeyondScope ? `<p class="faint">This conversation may continue into the next hour.</p>` : ""}</details>` : ""}
    <div class="row spread">${withHourLink ? `<a class="open" href="#/hour/${date}/${hour}">Open this hour <span class="arrow">↗</span></a>` : `<span class="open">Transcript and audio <span class="arrow">↗</span></span>`}</div></div>`);
  el.onclick = e => { if (!e.target.closest("a, details")) openRecord(x.id); };
  el.onkeydown = e => e.key === "Enter" && openRecord(x.id);
  return el;
}

// ---------- DAILY REFLECTION ----------
async function renderReflection(date) {
  if (!state.today) await loadDates();
  state.date = date;
  const [day, mem] = await Promise.all([api("day?date=" + date), api("memories")]);
  const r = day.reflection;
  if (!r) { view.innerHTML = topbar(backBtn("#/days/" + date), "Daily Reflection") + `<div class="empty">No reflection for ${esc(fmtDay(date))} yet.</div>`; wireBack(view); return; }
  const auday = r.pipeline === "auday";
  const st = r.stats || {};
  const highlights = day.hours.flatMap(x => x.highlights);
  const recorded = day.hours.reduce((n, x) => n + (x.recordedSeconds || 0), 0);
  const memories = (r.memories || []).map(id => mem.memories.find(m => m.id === id)).filter(Boolean);
  view.innerHTML = topbar(backBtn("#/days/" + date), "Daily Reflection", `<button class="round plain" id="shareRefl" aria-label="Share">${ICON.share}</button>`) + `
    <section class="refl-hero"><canvas width="880" height="400" aria-hidden="true"></canvas>
      <div class="inner"><div class="eyebrow">Daily Reflection · ${esc(fmtDay(date))}</div>
        <div class="cover">${esc(r.title)}</div>
        <div class="meta">${recorded ? fmtDur(recorded) + " recorded · " : ""}${plural(st.highlights ?? highlights.length, "Highlight")}${st.recordedHours != null ? ` · ${plural(st.recordedHours, "hour")} with audio` : ""}</div>
        ${r.windowStart ? `<div class="meta" style="margin-top:2px">${esc(fmtWhen(r.windowStart))} – ${esc(fmtWhen(r.start))}</div>` : ""}
        ${r.portrait ? portraitGrid(r.portrait) : ""}</div></section>
    ${auday ? `<h2>Summary</h2><p class="prose">${esc(r.summary || "")}</p>` : ""}
    <h2>Reflection</h2><p class="prose serif">${esc(r.text)}</p>
    ${r.quote ? `<p class="prose serif muted">“${esc(r.quote)}”</p>` : ""}
    ${(r.threads || []).map(t => `<p>· ${esc(t.text)} ${(t.source_ids || []).map(s => `<button class="cite" data-open="${esc(s)}">${esc((s.match(/T(\d\d)/) || [, "·"])[1])}:00</button>`).join("")}</p>`).join("")}
    ${auday ? `<div class="section-head"><h2>Daily Memory</h2><span class="count">${memories.length}</span></div>
      <p class="muted" style="margin-top:-4px">Review and edit today's selected memories.</p><div id="dailyMem"></div>` : ""}
    <div class="section-head"><h2>Highlights</h2><span class="count">${plural(highlights.length, "highlight")}</span></div><div id="reflHl"></div>
    <div class="refl-foot"><div class="faint">Updated ${esc(fmtWhen(r.updatedAt || r.start).replace(",", " ·"))} · based on ${plural(r.sourceIDs.length, "hour summary", "hour summaries")} · <button class="link small" data-open="${esc(r.id)}">sources</button></div></div>`;
  wireBack(view);
  drawDither($(".refl-hero canvas"), (r.portrait && r.portrait.seed) || hashSeed(r.id));
  const dm = $("#dailyMem");
  if (dm) {
    dm.innerHTML = memories.map((m, i) => `<button class="memcard" data-mem="${esc(m.id)}"><span class="n">${String(i + 1).padStart(2, "0")}</span>
      <span class="txt">${esc(m.content)}${m.status !== "candidate" ? `<br><span class="faint">${m.status === "rejected" ? "Ignored" : m.status === "inactive" ? "Inactive" : "Saved"}${m.edited ? " · Edited by you." : ""}</span>` : ""}</span><span class="arrow">↗</span></button>`).join("")
      || `<p class="faint">No memories were selected this day.</p>`;
    $$("[data-mem]", dm).forEach(b => b.onclick = () => openMemory(b.dataset.mem));
  }
  const box = $("#reflHl");
  highlights.forEach(x => box.append(highlightCard(x)));
  if (!highlights.length) box.innerHTML = `<p class="faint">No Highlights this day.</p>`;
  bindOpen(view);
  $("#shareRefl").onclick = async () => {
    const text = `${r.title}\n\n${auday ? r.summary + "\n\n" : ""}${r.text}`;
    try { if (navigator.share) await navigator.share({ title: "Daily Reflection", text }); else { await navigator.clipboard.writeText(text); toast("Copied"); } }
    catch (e) { /* share sheet closed without sharing */ }
  };
}

// ---------- YOUR WATCH (the browser microphone stands in for the Watch) ----------
// Audio is cut into 30 s files so each can be uploaded and transcribed on its own, like the
// Watch-to-iPhone sync in the real app. On the face: tap to start, tap to mark a moment, hold 1 s to stop.
function openWatch() {
  openSheet(`${sheetHead("Your Watch")}
    <div class="watch-hero">${ICON.logo}<div><div class="t1">The best AI hardware.</div><div class="t2">Maybe you already own it.</div></div></div>
    <div class="tip">${ICON.hand}<span>Hold the Watch screen for 1 second to stop recording.</span></div>
    <div class="devrow">${ICON.watchBig}<span class="name">This Mac's mic</span><span class="state" id="wState"></span></div>
    <div class="syncrow"><span>Awaiting sync</span><span class="v" id="wAwait">0s</span></div>
    <button class="btn big sync" id="wSync">Manually sync now ${ICON.sync}</button>
    <div class="syncnote">Automatically syncs every 30 seconds</div>
    <button class="face" id="wFace" aria-label="Watch screen">
      <svg class="hold" viewBox="0 0 232 232" preserveAspectRatio="none"><rect x="3" y="3" width="226" height="226" rx="59" pathLength="1000"/></svg>
      <span class="fdot"></span><span class="fbig" id="wTime">Tap to start</span>
      <span class="meter" id="wMeter">${"<i></i>".repeat(16)}</span><span class="ft" id="wHint"></span></button>
    <p class="muted" style="text-align:center;margin:6px 0 0">Open Auday on your Watch to start capturing — or use this Mac's microphone above. The watchOS app in <code>watch/</code> syncs here too.</p>
    <div class="watch-links">
      <details><summary>Can't connect your Apple Watch? ↗</summary>
        <p>Recordings go from the Watch to your iPhone. To get a copy on this Mac, open Settings › Connect to your workflow on the iPhone, tap Enable access, then run <code>python -m app.pair_iphone</code> here and type the password shown on the iPhone. Both need the same Wi-Fi.</p></details>
      <details><summary>Read the Watch Recording Tips</summary>
        <ul><li>Tap the screen to mark a moment; marked moments are kept and favoured for Highlights.</li>
          <li>Hold the screen for 1 second to stop recording.</li>
          <li>Quiet stretches keep their place on the timeline but store no sound (Settings › Automatic).</li>
          <li>Transcription runs on this Mac unless you choose a cloud service in Settings.</li></ul></details>
    </div>
`,
    () => { state.watchOpen = false; });
  state.watchOpen = true;
  const face = $("#wFace");
  let timer = null, held = false;
  const release = () => { if (timer) timer.cancel(); timer = null; face.classList.remove("holding"); };
  face.onpointerdown = e => {
    e.preventDefault(); held = false;
    if (!state.rec) return;
    face.classList.add("holding");
    // Stop only once the ring has visibly filled, not on a timer that can fire before it.
    // The fallback covers pages where transitions don't run; it still waits past the full second.
    const ring = $(".hold rect", face);
    const done = e => {
      if ((e && e.propertyName !== "stroke-dashoffset") || !face.classList.contains("holding")) return;
      held = true; release(); stopRecording();
    };
    ring.addEventListener("transitionend", done);
    const fallback = setTimeout(done, 1150);
    timer = { cancel: () => { ring.removeEventListener("transitionend", done); clearTimeout(fallback); } };
  };
  face.onpointerup = async () => {
    release();
    if (held) return;
    if (!state.rec) return startRecording();
    face.classList.add("flash"); setTimeout(() => face.classList.remove("flash"), 250);
    try { await api("marks", { body: { start: isoLocal() } }); toast("Marked this moment"); } catch (e) { toast(e.message); }
  };
  face.onpointerleave = release; face.onpointercancel = release;
  face.onkeydown = e => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); state.rec ? api("marks", { body: { start: isoLocal() } }).then(() => toast("Marked this moment")) : startRecording(); } };
  $("#wSync").onclick = () => syncNow();
  paintWatch();
}
function paintWatch() {
  const face = $("#wFace"); if (!face || !state.watchOpen) return;
  const rec = state.rec, up = state.uploading || 0;
  face.classList.toggle("on", !!rec);
  $("#wState").textContent = rec ? "Recording" : state.micError ? "Microphone blocked" : "Ready";
  $("#wState").classList.toggle("live", !!rec);
  const pending = rec ? (Date.now() - rec.segStart) / 1000 : 0;
  $("#wAwait").textContent = fmtDur(pending) + (up ? ` · ${up} uploading` : "");
  $("#wSync").disabled = !rec;
  $("#wHint").textContent = rec ? "Tap to mark · hold to stop" : "";
  $("#wMeter").style.display = rec ? "" : "none";
  if (!rec) $("#wTime").textContent = "Tap to start";
}

async function startRecording() {
  let stream;
  try { stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } }); }
  catch (e) { state.micError = true; paintWatch(); return toast("Can't use the microphone: " + e.message); }
  state.micError = false;
  const ctx = new AudioContext(), analyser = ctx.createAnalyser();
  ctx.createMediaStreamSource(stream).connect(analyser); analyser.fftSize = 64;
  state.rec = { stream, ctx, analyser, began: Date.now(), recorder: null };
  nextSegment();
  paintStatus(); paintWatch(); tickRecorder();
}
function nextSegment() {
  const rec = state.rec; if (!rec) return;
  const mime = ["audio/webm;codecs=opus", "audio/mp4", "audio/webm"].find(t => MediaRecorder.isTypeSupported(t)) || "";
  const recorder = new MediaRecorder(rec.stream, mime ? { mimeType: mime } : undefined);
  const start = isoLocal(), chunks = [];
  recorder.ondataavailable = e => e.data.size && chunks.push(e.data);
  recorder.onstop = () => {
    const blob = new Blob(chunks, { type: recorder.mimeType });
    if (blob.size > 2000) uploadAudio(blob, start, recorder.mimeType.includes("mp4") ? "m4a" : "webm");
  };
  recorder.start();
  rec.recorder = recorder; rec.segStart = Date.now();
  clearTimeout(rec.cut);
  rec.cut = setTimeout(() => { if (state.rec === rec) { recorder.stop(); nextSegment(); } }, 30000);
}
function syncNow() {           // Auday: Manually sync now — cut the current piece and upload it
  const rec = state.rec; if (!rec) return;
  if (rec.recorder.state !== "inactive") rec.recorder.stop();
  nextSegment(); toast("Syncing…");
}
function stopRecording() {
  const rec = state.rec; if (!rec) return;
  clearTimeout(rec.cut); state.rec = null;
  if (rec.recorder.state !== "inactive") rec.recorder.stop();
  rec.stream.getTracks().forEach(t => t.stop()); rec.ctx.close();
  toast("Recording stopped");
  paintStatus(); paintWatch();
}
function tickRecorder() {
  const rec = state.rec;
  if (!rec) return;
  const time = $("#wTime");
  if (time && state.watchOpen) {
    const secs = (Date.now() - rec.began) / 1000 | 0;
    time.textContent = `${String(secs / 60 | 0).padStart(2, "0")}:${String(secs % 60).padStart(2, "0")}`;
    const data = new Uint8Array(rec.analyser.frequencyBinCount); rec.analyser.getByteFrequencyData(data);
    $$("#wMeter i").forEach((b, i) => (b.style.height = 3 + (data[i] || 0) / 255 * 23 + "px"));
    if (!tickRecorder.n || Date.now() - tickRecorder.n > 500) { tickRecorder.n = Date.now(); paintWatch(); }
  }
  requestAnimationFrame(tickRecorder);
}
async function uploadAudio(blob, start, ext) {
  state.uploading = (state.uploading || 0) + 1; paintWatch();
  try { await api(`audio?start=${encodeURIComponent(start)}&ext=${ext}`, { body: blob }); }
  catch (e) { toast("Upload failed: " + e.message); }
  finally { state.uploading--; paintWatch(); }
}
// ---------- CHAT (Auday AI) ----------
const SUGGESTIONS = ["Help me find that idea I mentioned recently.", "What could I have done better lately?", "What needs my attention next week?"];
async function renderChat() {
  if (!state.settings) state.settings = await api("settings").catch(() => ({}));
  const s = state.settings || {};
  const model = s.provider === "none" ? "AI is off" : s.model || "";
  view.innerHTML = topbar(`<div class="brand" style="font-size:19px">Auday AI</div>`, "",
    `<a class="round plain" href="#/memory" aria-label="Your memory">${ICON.stack}</a>
     <button class="round plain" id="historyBtn" aria-label="Conversations">${ICON.clock}</button>
     <button class="round plain" id="newChat" aria-label="New conversation">${ICON.compose}</button>`) + `
    <div id="chatBody"></div>
    <form class="composer" id="composer"><div class="box"><textarea rows="1" id="q" placeholder="Ask about your days…"></textarea>
      <button class="send" id="sendBtn" aria-label="Send">${ICON.send}</button></div><div class="model">${esc(model)}</div></form>`;
  $("#historyBtn").onclick = openConversations;
  $("#newChat").onclick = () => { if (state.chatBusy) state.chatBusy.abort(); state.chat = []; state.conversation = null; drawChat(); $("#q").focus(); };
  $("#composer").onsubmit = e => { e.preventDefault(); state.chatBusy ? state.chatBusy.abort() : sendChat($("#q").value); };
  const q = $("#q");
  q.onkeydown = e => { if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); if (!state.chatBusy) sendChat(q.value); } };
  q.oninput = () => { q.style.height = "auto"; q.style.height = Math.min(120, q.scrollHeight) + "px"; };
  if (state.chatDraft) { q.value = state.chatDraft; state.chatDraft = null; }
  drawChat();
}
function drawChat() {
  const body = $("#chatBody"); if (!body) return;
  const send = $("#sendBtn");
  if (send) { send.innerHTML = state.chatBusy ? ICON.stop : ICON.send; send.setAttribute("aria-label", state.chatBusy ? "Stop" : "Send"); }
  if (!state.chat.length) {
    body.innerHTML = `<div class="chat-empty"><div class="eyebrow">Your life is the context</div>
      <h1 class="serif">Less explaining.<br>More understanding.</h1>
      <p class="muted">Your conversations, memories and daily rhythms help Auday AI understand you — so you can ask without setting the scene.</p>
      <div class="suggestions">${SUGGESTIONS.map(q => `<button data-q="${esc(q)}"><span>${esc(q)}</span><span class="arrow">↖</span></button>`).join("")}</div>
      <p class="faint">Answers link back to the transcript and original audio.</p></div>`;
    $$("[data-q]", body).forEach(b => b.onclick = () => sendChat(b.dataset.q));
    return;
  }
  const list = h(`<div class="chat"></div>`);
  state.chat.forEach((m, i) => {
    if (m.pending) return list.append(h(`<div class="msg assistant pending">Reading your days</div>`));
    if (m.failed) {
      const el = h(`<div class="msg assistant failed">No answer was saved. You can ask this question again.
        ${m.error ? `<div class="faint">${esc(m.error)}</div>` : ""}<div><button class="btn small">Ask again</button></div></div>`);
      $("button", el).onclick = () => { const q = state.chat[i - 1].content; state.chat.splice(i - 1, 2); sendChat(q); };
      return list.append(el);
    }
    const el = h(`<div class="msg ${m.role}"></div>`);
    if (m.role === "assistant") {
      const order = m.cited || [];
      el.innerHTML = esc(m.content).replace(/\[((?:transcript|highlight|summary|reflection|mem)[-_][\w:.\-]+)\]/g, (all, id) => {
        const n = order.indexOf(id); return n < 0 ? "" : `<button class="cite" data-open="${esc(id)}">${n + 1}</button>`;
      });
    } else el.textContent = m.content;
    list.append(el);
  });
  body.replaceChildren(list);
  bindOpen(list);
  window.scrollTo(0, document.body.scrollHeight);
}
async function sendChat(question) {
  question = (question || "").trim(); if (!question || state.chatBusy) return;
  const history = state.chat.filter(m => !m.pending && !m.failed).slice(-6).map(m => ({ role: m.role, content: m.content }));
  state.chat.push({ role: "user", content: question }, { role: "assistant", pending: true });
  if ($("#q")) { $("#q").value = ""; $("#q").style.height = "auto"; }
  const ctrl = new AbortController(); state.chatBusy = ctrl;
  drawChat();
  let reply;
  try {
    const r = await api("chat", { body: { question, history, conversation: state.conversation }, signal: ctrl.signal });
    state.conversation = r.conversation || state.conversation;
    reply = { role: "assistant", content: r.answer, cited: r.cited };
  } catch (e) { reply = { role: "assistant", failed: true, error: ctrl.signal.aborted ? "Stopped." : e.message }; }
  state.chatBusy = null;
  state.chat[state.chat.length - 1] = reply;
  drawChat();
}
async function openConversations() {
  const { conversations } = await api("chat/conversations");
  openSheet(`${sheetHead("Conversations", `<button class="done" data-close>Done</button>`)}
    ${conversations.map(c => `<button class="convo ${c.id === state.conversation ? "on" : ""}" data-c="${esc(c.id)}"><div class="q clamp2">${esc(c.question || "(no question)")}</div>
      <div class="faint">${esc(fmtWhen(c.ts))} · ${plural(Math.ceil(c.messages / 2), "question")}</div></button>`).join("")
      || `<div class="empty">No conversations yet.</div>`}`);
  $$("[data-c]", $("#sheetBody")).forEach(b => b.onclick = async () => {
    state.conversation = b.dataset.c;
    state.chat = await api("chat?conversation=" + encodeURIComponent(b.dataset.c));
    closeSheet(); if (route().name === "chat") drawChat(); else nav("#/chat");
  });
}

// ---------- SEARCH ----------
function scopeLabel(sc = state.scope) {
  const t = state.today;
  if (sc.kind === "all") return "All days";
  if (sc.kind === "day") return sc.date === t ? "Today" : fmtDay(sc.date);
  if (sc.kind === "range") {
    if (sc.to === t && sc.from === addDays(t, -6)) return "Last 7 days";
    if (sc.to === t && sc.from === addDays(t, -29)) return "Last 30 days";
    return `${fmtDay(sc.from)} – ${fmtDay(sc.to)}`;
  }
  return plural(sc.dates.length, "day");
}
function scopeQuery(sc = state.scope) {
  if (sc.kind === "day") return `&date=${sc.date}`;
  if (sc.kind === "range") return `&from=${sc.from}&to=${sc.to}`;
  if (sc.kind === "days") return `&dates=${sc.dates.join(",")}`;
  return "";
}
async function renderSearch() {
  if (!state.today) await loadDates();
  view.innerHTML = topbar("", "", `<button class="btn small scopebtn" id="scopeBtn">${esc(scopeLabel())} ▾</button>`) +
    `<div class="searchhead"><h1 class="serif">Find it in your day</h1><div class="muted">Keyword and semantic search</div></div>
    <form class="searchbox" id="sform">${ICON.search}<input id="sq" type="search" placeholder="Words, names or what it was about" autocomplete="off" enterkeyhint="search"></form>
    <div class="modes" id="smode">${[["hybrid", "Hybrid"], ["keyword", "Keyword"], ["semantic", "Semantic"]].map(([m, l]) => `<button data-m="${m}" class="${state.searchMode === m ? "active" : ""}">${l}</button>`).join("")}</div>
    <div id="sres"></div>`;
  $("#scopeBtn").onclick = openScope;
  $$("[data-m]").forEach(b => b.onclick = () => { state.searchMode = b.dataset.m; $$("[data-m]").forEach(x => x.classList.toggle("active", x === b)); if ($("#sq").value.trim()) runSearch(); });
  $("#sform").onsubmit = e => { e.preventDefault(); runSearch(); };
  $("#sq").oninput = () => { if (!$("#sq").value.trim()) searchIdle(); };
  if (state.lastQuery) { $("#sq").value = state.lastQuery; runSearch(); } else searchIdle();
}
function searchIdle() {
  state.lastQuery = "";
  const recent = store("recentSearches") || [];
  $("#sres").innerHTML = `<div class="section-head" style="margin-top:22px"><h2>Recent searches</h2>${recent.length ? `<button class="btn text small" id="clearRecent">Clear</button>` : ""}</div>
    ${recent.length ? `<div class="recent">${recent.map(q => `<button data-r="${esc(q)}">${ICON.clock}<span>${esc(q)}</span></button>`).join("")}</div>` : `<p class="muted">No recent searches</p>`}
    <div class="explore card"><h3 class="serif" style="font-size:21px;font-weight:500">Want to explore further?</h3>
      <p class="muted" style="margin:4px 0 10px">Chat can follow a thread for you across days, memories and Highlights.</p>
      <a class="link" href="#/chat" id="askChat">Ask Chat ↗</a></div>`;
  $$("[data-r]").forEach(b => b.onclick = () => { $("#sq").value = b.dataset.r; runSearch(); });
  if ($("#clearRecent")) $("#clearRecent").onclick = () => { store("recentSearches", []); searchIdle(); };
}
async function runSearch() {
  const q = $("#sq").value.trim(); if (!q) return searchIdle();
  state.lastQuery = q;
  store("recentSearches", [q, ...(store("recentSearches") || []).filter(x => x !== q)].slice(0, 8));
  $("#sres").innerHTML = `<p class="muted">Searching…</p>`;
  let res;
  try { res = await api(`search?q=${encodeURIComponent(q)}&mode=${state.searchMode}${scopeQuery()}`); }
  catch (e) { $("#sres").innerHTML = `<p class="muted">Search failed: ${esc(e.message)}</p>`; return; }
  const mark = s => esc(s).replace(new RegExp(esc(q).replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "gi"), x => `<mark>${x}</mark>`);
  $("#sres").innerHTML = `<div class="section-head" style="margin-top:18px"><h2>${res.length ? plural(res.length, "result") : "Nothing found"}</h2><span class="count">${esc(scopeLabel())}</span></div>` +
    res.map(r => `<div class="card result" data-open="${esc(r.id)}">
      <div class="row spread"><span class="eyebrow" style="font-size:11px">${esc(KIND[r.kind] || r.kind)}</span><span class="faint">${esc(fmtWhen(r.start))}</span></div>
      ${r.title ? `<h3 style="margin-top:6px">${esc(r.title)}</h3>` : ""}<div class="snippet">${mark(r.snippet)}</div></div>`).join("") +
    `<div class="explore card"><p class="muted" style="margin:0 0 8px">Not quite it? Chat can look across your days for you.</p><a class="link" href="#/chat" id="askChat">Ask Chat about “${esc(q)}” ↗</a></div>`;
  bindOpen($("#sres"));
  $("#askChat").onclick = () => { state.chatDraft = q; };
}

// Auday's Search scope: quick ranges, One day / Date range / Several days, and a calendar.
function openScope() {
  const t = state.today;
  let draft = JSON.parse(JSON.stringify(state.scope));
  let mode = draft.kind === "range" ? "range" : draft.kind === "days" ? "days" : "day";
  let month = dayDate(draft.date || draft.to || (draft.dates && draft.dates[0]) || t); month.setDate(1);
  const quick = [["Today", { kind: "day", date: t }], ["Last 7 days", { kind: "range", from: addDays(t, -6), to: t }],
    ["Last 30 days", { kind: "range", from: addDays(t, -29), to: t }], ["All days", { kind: "all" }]];
  const draw = () => {
    openSheet(`<div class="sheetbar"><button class="btn text" data-close>Cancel</button><span class="title">Search scope</span><button class="btn text" id="applyScope" style="color:var(--text);font-weight:650">Apply</button></div>
      <h2 style="margin-top:6px">Choose the days to search.</h2>
      <div class="pills">${quick.map(([l, sc], i) => `<button data-qi="${i}" class="${scopeLabel(draft) === l ? "on" : ""}">${l}</button>`).join("")}</div>
      <div class="seg">${[["day", "One day"], ["range", "Date range"], ["days", "Several days"]].map(([m, l]) => `<button data-mode="${m}" class="${mode === m ? "active" : ""}">${l}</button>`).join("")}</div>
      <div class="cal">${calendarHTML(month, draft)}</div>
      <p class="faint" style="text-align:center">${esc(scopeLabel(draft))}</p>`);
    $$("[data-qi]").forEach(b => b.onclick = () => { draft = { ...quick[b.dataset.qi][1] }; mode = draft.kind === "range" ? "range" : "day"; draw(); });
    $$("[data-mode]").forEach(b => b.onclick = () => { mode = b.dataset.mode; draw(); });
    $$("[data-month]").forEach(b => b.onclick = () => { month.setMonth(month.getMonth() + +b.dataset.month); draw(); });
    $$(".cal [data-d]").forEach(b => b.onclick = () => {
      const d = b.dataset.d;
      if (mode === "day") draft = { kind: "day", date: d };
      else if (mode === "range") {
        if (draft.kind === "range" && draft.from === draft.to && d > draft.from) draft = { kind: "range", from: draft.from, to: d };
        else draft = { kind: "range", from: d, to: d };
      } else {
        const set = new Set(draft.kind === "days" ? draft.dates : []);
        set.has(d) ? set.delete(d) : set.add(d);
        draft = set.size ? { kind: "days", dates: [...set].sort() } : { kind: "all" };
      }
      draw();
    });
    $("#applyScope").onclick = () => { state.scope = draft; closeSheet(); $("#scopeBtn").textContent = scopeLabel() + " ▾"; if ($("#sq").value.trim()) runSearch(); };
  };
  draw();
}
function calendarHTML(month, sc) {
  const y = month.getFullYear(), m = month.getMonth();
  const first = new Date(y, m, 1), days = new Date(y, m + 1, 0).getDate(), lead = (first.getDay() + 6) % 7;
  const cells = Array(lead).fill(`<span></span>`);
  for (let i = 1; i <= days; i++) {
    const d = ymd(new Date(y, m, i, 12));
    const on = (sc.kind === "day" && sc.date === d) || (sc.kind === "range" && (sc.from === d || sc.to === d)) || (sc.kind === "days" && sc.dates.includes(d));
    const inside = sc.kind === "range" && d > sc.from && d < sc.to;
    const cls = ["d", on && "on", inside && "in", state.dates.includes(d) && "has", d === state.today && "today"].filter(Boolean).join(" ");
    cells.push(`<button class="${cls}" data-d="${d}" ${d > state.today ? "disabled" : ""}>${i}</button>`);
  }
  return `<div class="calhead"><button class="round plain" data-month="-1" aria-label="Previous month">${ICON.back}</button><span>${MONTHS_LONG[m]} ${y}</span>
      <button class="round plain" data-month="1" aria-label="Next month" style="transform:scaleX(-1)">${ICON.back}</button></div>
    <div class="grid">${["M", "T", "W", "T", "F", "S", "S"].map(d => `<span class="dow">${d}</span>`).join("")}${cells.join("")}</div>`;
}
// The Days calendar button: pick one day.
function pickDay(current, done) {
  const month = dayDate(current); month.setDate(1);
  const draw = () => {
    openSheet(`${sheetHead("Choose a day")}<div class="cal">${calendarHTML(month, { kind: "day", date: current })}</div>
      <div class="row" style="justify-content:center;margin-top:10px"><button class="btn" id="goToday">Today</button></div>`);
    $$("[data-month]").forEach(b => b.onclick = () => { month.setMonth(month.getMonth() + +b.dataset.month); draw(); });
    $$(".cal [data-d]").forEach(b => b.onclick = () => { closeSheet(); done(b.dataset.d); });
    $("#goToday").onclick = () => { closeSheet(); done(state.today); };
  };
  draw();
}

// ---------- YOUR MEMORY ----------
const MEM_TABS = {
  review: ["Review", m => m.status === "candidate", "Memories you haven't reviewed are saved automatically after 5 days."],
  saved: ["Saved", m => ["saved", "confirmed"].includes(m.status), "These memories help Auday AI understand you."],
  inactive: ["Inactive", m => ["inactive", "rejected", "superseded"].includes(m.status), "Auday AI no longer uses these memories. Earlier summaries and chats are not rewritten."],
};
function memoryMeta(m) {
  const from = m.observed_at ? ` · From ${fmtWhen(m.observed_at, false)}` : "";
  if (m.status === "candidate") {
    const left = m.created_at ? Math.max(0, 5 - Math.floor((Date.now() - Date.parse(m.created_at)) / 864e5)) : null;
    return `Added ${fmtWhen(m.created_at || m.observed_at)}${from}${state.pipeline === "auday" && left !== null ? ` · saves automatically in ${plural(left, "day")}` : ""}`;
  }
  if (["saved", "confirmed"].includes(m.status)) {
    const auto = /auto-saved/.test(m.status_reason || "") ? " automatically" : "";
    return `Saved${auto} ${fmtWhen(m.savedAt || m.created_at)}${from}`;
  }
  if (m.status === "rejected") return `Ignored ${fmtWhen(m.inactivatedAt)}${from}`;
  if (m.status === "superseded") return `Replaced by a newer memory${from}`;
  return `Inactive since ${fmtWhen(m.inactivatedAt)}${from}`;
}
function memoryItem(m, conflict = false) {
  const buttons = {
    candidate: [["confirm", "This is about me", "btn ink small"], ["edit", "Edit", "btn text"], ["reject", "Ignore", "btn text"]],
    saved: [["edit", "Edit", "btn text"], ["deactivate", "Deactivate", "btn text"]],
    confirmed: [["edit", "Edit", "btn text"], ["deactivate", "Deactivate", "btn text"]],
    inactive: [["reactivate", "Use again", "btn text"]],
  }[m.status] || [];
  const dim = ["superseded", "rejected", "inactive"].includes(m.status);
  return `<div class="mem ${dim ? "dim" : ""} ${conflict ? "review-conflict" : ""}" data-id="${esc(m.id)}">
    <div class="meta">${esc(memoryMeta(m))}</div>
    <div class="content serif">${esc(m.content)}</div>
    ${m.edited ? `<div class="edited">Edited by you.</div>` : ""}
    ${conflict ? `<div class="faint" style="color:var(--warn)">Conflicts with a saved memory — please check.</div>` : ""}
    ${m.attribution === "inferred" || m.certainty === "tentative" || m.valid_until ? `<div class="chips">${m.attribution === "inferred" ? `<span class="chip warn">Inferred</span>` : ""}${m.certainty === "tentative" ? `<span class="chip warn">Unsure</span>` : ""}${m.valid_until ? `<span class="chip info">Until ${esc(m.valid_until)}</span>` : ""}</div>` : ""}
    <div class="actions">${buttons.map(([a, t, cls]) => `<button class="${cls}" data-act="${a}">${t}</button>`).join("")}<button class="btn text" data-act="history" style="margin-left:auto">Details</button></div></div>`;
}
function bindMemoryActions(root, after) {
  bindOpen(root);
  $$(".mem [data-act]", root).forEach(b => b.onclick = async () => {
    const item = b.closest(".mem"), id = item.dataset.id, act = b.dataset.act;
    if (act === "history") return openMemory(id);
    if (act === "edit") return editMemory(item, after);
    try { await api(`memories/${id}/${act}`, { body: {} }); toast({ confirm: "Saved", reject: "Ignored", deactivate: "Deactivated", reactivate: "In use again" }[act] || "Updated"); }
    catch (e) { return toast(e.message); }
    after ? after() : render();
  });
}
// Inline edit, as on the phone: saving counts as your confirmation.
function editMemory(item, after) {
  const text = $(".content", item).textContent;
  const actions = $(".actions", item);
  $(".content", item).outerHTML = `<textarea>${esc(text)}</textarea>`;
  actions.innerHTML = `<button class="btn ink small" data-save>Save</button><button class="btn text" data-cancel>Cancel</button>`;
  const area = $("textarea", item); area.focus();
  $("[data-cancel]", item).onclick = () => after ? after() : render();
  $("[data-save]", item).onclick = async () => {
    const content = area.value.trim(); if (!content) return;
    try { await api(`memories/${item.dataset.id}/edit`, { body: { content } }); toast("Saved"); } catch (e) { return toast(e.message); }
    after ? after() : render();
  };
}
async function renderMemory() {
  const data = await api("memories");
  const conflicts = new Set(data.reviews.map(r => r.memory_id));
  const [, filter, note] = MEM_TABS[state.memTab];
  const list = data.memories.filter(filter);
  view.innerHTML = topbar(backBtn("#/days"), "Your memory") + `
    <div class="memhead"><h1 class="serif">What stays with you.</h1></div>
    <div class="seg">${Object.entries(MEM_TABS).map(([k, [t, f]]) => `<button data-f="${k}" class="${k === state.memTab ? "active" : ""}">${t} ${data.memories.filter(f).length || ""}</button>`).join("")}</div>
    <p class="muted">${note}</p>
    ${state.memTab === "review" && data.reviews.length ? `<p class="faint" style="color:var(--warn)">Waiting for you: ${plural(data.reviews.length, "memory", "memories")} in conflict with saved ones.</p>` : ""}
    <div id="memList"></div>`;
  wireBack(view);
  $$("[data-f]").forEach(b => b.onclick = () => { state.memTab = b.dataset.f; renderMemory(); });
  const box = $("#memList");
  box.innerHTML = list.map(m => memoryItem(m, conflicts.has(m.id))).join("") || `<div class="empty">Nothing here yet.</div>`;
  bindMemoryActions(box);
}

// ---------- SETTINGS ----------
// Like Auday's "Your archive": days, audio stored, Start transcription when automatic
// transcription is off, and a batch export of Notes and audio.
async function renderArchive() {
  const box = $("#archiveCard");
  if (!box) return;
  const a = await api("archive");
  const today = ymd(new Date());
  box.innerHTML = `<h3>Your archive</h3>
    <div class="stats"><div><b>${a.days}</b><span>days</span></div><div><b>${(a.audioBytes / 1e6).toFixed(0)} MB</b><span>audio stored</span></div>
      <div><b>${Math.round(a.pendingSeconds / 60)} min</b><span>to transcribe</span></div></div>
    ${a.pendingAudio ? `<div class="row" style="margin:8px 0"><button class="btn small" id="transcribeNext">Start transcription (about 15 min)</button></div>` : ""}
    <div class="row wrap" style="gap:8px;align-items:flex-end"><label class="field" style="margin:0;flex:1"><span>From</span><input type="date" id="exFrom" value="${today}"></label>
      <label class="field" style="margin:0;flex:1"><span>To</span><input type="date" id="exTo" value="${today}"></label>
      <button class="btn small" id="batchExport">Batch export (Notes and audio)</button></div>`;
  if ($("#transcribeNext")) $("#transcribeNext").onclick = async () => { const r = await api("transcribe", { body: {} }); toast(`Queued ${r.queued} pieces, about ${Math.round(r.seconds / 60)} min`); };
  $("#batchExport").onclick = () => { location.href = `/api/batch-export?from=${$("#exFrom").value}&to=${$("#exTo").value}`; };
}

// Like Auday's "Connect to your workflow": the official Auday Skill on a computer on this network finds
// the replica, pairs with the communication password and syncs read-only (app/workflow_server.py).
async function renderWorkflow() {
  const box = $("#workflowCard");
  if (!box) return;
  const w = await api("workflow");
  const STATE = { on: "On, visible on this network", starting: "Starting…", error: "Could not start", off: "Off" };
  box.innerHTML = `<h3>Connect to your workflow <span class="chip ${w.state === "on" ? "ok" : w.state === "error" ? "warn" : ""}">${STATE[w.state] || w.state}</span></h3>
    <p class="faint">On a computer on the same Wi-Fi, the official Auday Skill can find this Mac, pair with the communication password below and sync read-only. Data stays on your local network and never goes through a server.</p>
    <label class="toggle"><span>Allow the Skill to read</span><input type="checkbox" id="wfEnabled" ${w.enabled ? "checked" : ""}></label>
    <label class="field"><span>What it may read (always read-only)</span><select id="wfAccess">${[["text", "All text"], ["text-and-audio", "Text and audio"]].map(([v, l]) => `<option value="${v}" ${w.access === v ? "selected" : ""}>${l}</option>`).join("")}</select></label>
    ${w.password ? `<p>Communication password: <b style="font-family:ui-monospace,monospace;letter-spacing:1px">${esc(w.password)}</b></p>
      <p class="faint">Type it only into the Skill's local pairing prompt, never into a chat. After a new password, paired computers have to pair again.</p>` : ""}
    <div class="row wrap" style="gap:6px"><button class="btn small" id="wfRegenerate">New password</button>
      <input id="wfOwn" placeholder="Or enter your own 16-character password (2–9, A–Z, no I or O)" autocomplete="off" style="flex:1;min-width:200px;border:1px solid var(--line);background:var(--raised);border-radius:12px;padding:7px 10px"><button class="btn small ghost" id="wfSetOwn">Use</button></div>
    <p class="faint" style="margin-top:8px">Service ${esc(w.name)}${w.port ? ` · port ${w.port}` : ""}${w.error ? ` · ${esc(w.error)}` : ""}</p>`;
  const send = async body => {
    try { await api("workflow", { body }); } catch (e) { return toast("Not saved: " + e.message); }
    setTimeout(renderWorkflow, 600);
  };
  $("#wfEnabled").onchange = e => send({ enabled: e.target.checked });
  $("#wfAccess").onchange = e => send({ access: e.target.value });
  $("#wfRegenerate").onclick = () => send({ regenerate: true });
  $("#wfSetOwn").onclick = () => $("#wfOwn").value.trim() && send({ password: $("#wfOwn").value.trim() });
  if (w.state === "starting") setTimeout(renderWorkflow, 1500);
}

async function renderSettings(section) {
  const [s, st] = await Promise.all([api("settings"), api("status")]);
  state.settings = s;
  const t = (k, label, hint) => `<label class="toggle"><span>${label}${hint ? `<br><span class="faint">${hint}</span>` : ""}</span><input type="checkbox" data-k="${k}" ${s[k] ? "checked" : ""}></label>`;
  const LANGS = ["English", "Chinese", "Cantonese", "Japanese", "Korean"];
  const LANG_NAMES = { English: "English", Chinese: "普通话", Cantonese: "粤语", Japanese: "日本語", Korean: "한국어" };
  const lang = (k, label, optional) => `<label class="field"><span>${label}</span><select data-k="${k}">${(optional ? [""] : []).concat(LANGS).map(v => `<option value="${v}" ${s[k] === v ? "selected" : ""}>${v ? LANG_NAMES[v] : "None"}</option>`).join("")}</select></label>`;
  const f = (k, label, type = "text") => `<label class="field"><span>${label}</span><input data-k="${k}" type="${type}" value="${esc(s[k])}"></label>`;
  const reviewCount = (state.status && state.status.reviewCount) || 0;
  view.innerHTML = topbar(backBtn("#/days"), "Settings") + `
    <a class="navrow" href="#/memory"><span>Your memory</span><span class="muted">${reviewCount ? `${reviewCount} to review ` : ""}›</span></a>
    <button class="navrow" id="openWatchRow"><span>Your Watch</span><span class="muted">›</span></button>
    <div class="group-title">AI service</div>
    <div class="card"><p class="faint" style="margin-top:0">Summaries, Highlights, reflections, memory and Chat go only to the service you set here. The default is the local model on this Mac (mlx_lm.server).</p>
      <label class="field"><span>Service</span><select data-k="provider">${[["openai", "OpenAI-compatible (local MLX / Ollama / OpenAI)"], ["anthropic", "Anthropic"], ["gemini", "Gemini"], ["none", "AI features off"]].map(([v, l]) => `<option value="${v}" ${s.provider === v ? "selected" : ""}>${l}</option>`).join("")}</select></label>
      ${f("base_url", "Address")}${f("model", "Model")}${f("api_key", "API key (leave empty for a local model)", "password")}${f("system_prefix", "System prompt prefix (/no_think turns off thinking for SmolLM3/Qwen3)")}
      <div class="row wrap"><button class="btn small" id="checkAI">Check Connection &amp; Save</button><span class="faint" id="checkResult"></span></div></div>
    <div class="group-title">Processing</div>
    <div class="card">
      <label class="field"><span>Pipeline</span><select data-k="pipeline">${[["improved", "Improved: separate memory extraction with verbatim evidence"], ["auday", "Auday: the same steps as the real app, as measured"]].map(([v, l]) => `<option value="${v}" ${s.pipeline === v ? "selected" : ""}>${l}</option>`).join("")}</select></label>
      <label class="field"><span>How mixed voices (Me*) go to the AI</span><select data-k="voice_labels">${[["auday", "As in Auday: counted as the owner (me:1)"], ["improved", "Marked as mixed, not counted as the owner's words"]].map(([v, l]) => `<option value="${v}" ${s.voice_labels === v ? "selected" : ""}>${l}</option>`).join("")}</select></label>
      ${lang("primary_language", "Primary language (everything the AI writes)", false)}${lang("secondary_language", "Second language (only helps transcription; the AI still writes in the primary language)", true)}
      <label class="field"><span>Daily Reflection time (a day is the 24 hours ending at this time)</span><input data-k="reflection_time" type="time" value="${esc(s.reflection_time)}"></label></div>
    <div class="group-title">Voice</div>
    <div class="card" id="voiceCard"><h3>Your voice ${st.voiceprint ? '<span class="chip ok">Enrolled</span>' : '<span class="chip warn">Not enrolled</span>'}</h3>
      <p class="faint">As in Auday, read three passages, about 45 seconds in all, so your own voice can be told apart from others. If you speak two languages, use both across the three passages; this improves recognition. The recording is processed only on this Mac.</p>
      <ol class="readings"><li>今天早上天气不错，我骑车去学校，路上买了一杯咖啡。下午有两节课，晚上回家做饭，然后看一会儿书。</li>
        <li>Seven, three, nine, one, four. The quick brown fox jumps over the lazy dog. I usually take the train to San Francisco on weekends.</li>
        <li>一二三四五，六七八九十。我平时说话就是这个音量，有时候中文和 English 会混着说，就像现在这样。</li></ol>
      <div class="row wrap"><button class="btn small" id="voiceRec">Start reading</button><span class="faint" id="voiceTime"></span>
</div></div>
    <div class="group-title">Body &amp; location data</div>
    <div class="card"><p class="faint" style="margin-top:0">Like Auday's Body data: heart rate, HRV, walking and stress states go to your AI with Highlights, summaries and reflections. The iPhone reads them straight from Health and they arrive with each sync once the iPhone is connected to this Mac. Nothing to export or import.</p>
      ${t("body_data", "Body data")}
      ${t("location_data", "Location data", "Like Auday's Location data: where your Watch was while recording, named roughly by the iPhone (which sends the coordinates to Apple to look up the name). Only the place name and times go to the AI, never coordinates.")}
      <p class="faint">Available</p></div>
    <div class="group-title">Workflow</div>
    <div class="card" id="workflowCard"><h3>Connect to your workflow</h3><p class="faint">Loading…</p></div>
    <div class="group-title">Automatic</div>
    <div class="card">${t("auto_transcribe", "Automatic transcription")}${t("auto_hourly", "Hourly Highlights & summary", "When each hour ends, its summary and Highlights are written")}${t("auto_daily", "Daily Reflection", "At the Reflection time, the day's reflection and memory candidates are written")}${t("omit_silence", "Skip storing very quiet audio", "As in Auday: the timeline is kept and plays back as silence of the same length; nothing is cut around marks")}${t("auto_memory", "Remember facts from conversations", "Only what you said yourself; uncertain facts become candidates")}${t("mic_is_me", "Treat the microphone as me", "A shortcut when there is no voiceprint")}</div>
    <div class="group-title">Transcription &amp; search</div>
    <div class="card">
      <label class="field"><span>Transcription model</span><select data-k="whisper_model">${[["sensevoice", "Local efficient · SenseVoice (Mandarin, Cantonese, English, Japanese, Korean; with emotion)"], ["base", "Local accurate · Whisper base"], ["small", "Local accurate · Whisper small"], ["medium", "Local accurate · Whisper medium"], ["remote", "Cloud or self-hosted service (your own key)"]].map(([v, label]) => `<option value="${v}" ${s.whisper_model === v ? "selected" : ""}>${label}</option>`).join("")}</select></label>
      <label class="field"><span>Cloud service format</span><select data-k="asr_service">${[["openai", "OpenAI-compatible /audio/transcriptions (OpenAI, Groq, self-hosted Whisper, Qwen compatible mode)"], ["deepgram", "Deepgram (Nova-3 suits mixed languages; no Chinese)"]].map(([v, l]) => `<option value="${v}" ${s.asr_service === v ? "selected" : ""}>${l}</option>`).join("")}</select></label>
      ${f("asr_base_url", "Cloud service address (may be empty for Deepgram)")}${f("asr_model", "Cloud model (e.g. whisper-1, nova-3)")}${f("asr_api_key", "Cloud service API key", "password")}
      <label class="field"><span>Keep original audio</span><select data-k="audio_retention_days">${[[0, "Forever"], [30, "30 days"], [7, "7 days"], [1, "1 day"]].map(([v, l]) => `<option value="${v}" ${Number(s.audio_retention_days) === v ? "selected" : ""}>${l}</option>`).join("")}</select></label>
      <label class="field"><span>Transcription language (like Auday's Local efficient mode, these 5 only)</span><select data-k="language">${[["", "Detect automatically"], ["zh", "普通话"], ["yue", "粤语"], ["en", "English"], ["ja", "日本語"], ["ko", "한국어"]].map(([v, l]) => `<option value="${v}" ${s.language === v ? "selected" : ""}>${l}</option>`).join("")}</select></label>
      <label class="field"><span>Embedding model</span><select data-k="embedder"><option value="hash" ${s.embedder === "hash" ? "selected" : ""}>Offline lexical vectors (default)</option><option value="http" ${s.embedder === "http" ? "selected" : ""}>OpenAI-compatible /v1/embeddings (e.g. EmbeddingGemma)</option></select></label>
      ${f("embed_url", "Embedding address")}${f("embed_model", "Embedding model name")}</div>
    <div class="group-title" id="archive">Archive</div>
    <div class="card" id="archiveCard"><h3>Your archive</h3><p class="faint">Loading…</p></div>
    <div class="row wrap" style="margin:16px 0"><button class="btn ink" id="saveSettings">Save settings</button><button class="btn" id="exportBtn">Export library.json</button></div>
    <div class="group-title">Status</div>
    <div class="card">
      <p class="faint" style="margin-top:0">Transcripts ${st.counts.transcript || 0} · Highlights ${st.counts.highlight || 0} · Summaries ${st.counts.summary || 0} · Reflections ${st.counts.reflection || 0} · Memories ${st.counts.memory} · Conflicts ${st.openReviews}<br>
      Queue ${st.queue}${st.current ? " · now " + esc(st.current) : ""} · LLM calls this run ${st.usage.calls}, ${st.usage.input_tokens} / ${st.usage.output_tokens} tokens</p>
      <div class="log">${st.activity.slice().reverse().map(a => `<div class="${a.ok ? "" : "bad"}">${esc(a.ts)} ${esc(a.text)}</div>`).join("") || "Nothing yet"}</div></div>`;
  wireBack(view);
  const collect = () => { const changes = {}; $$("[data-k]", view).forEach(el => (changes[el.dataset.k] = el.type === "checkbox" ? el.checked : el.value)); return changes; };
  $("#saveSettings").onclick = async () => { state.settings = await api("settings", { method: "PUT", body: collect() }).catch(e => (toast(e.message), state.settings)); toast("Saved"); };
  $("#checkAI").onclick = async () => {
    await api("settings", { method: "PUT", body: collect() }); state.settings = null;
    const r = await api("check", { body: {} });
    $("#checkResult").textContent = r.ok ? "Connected and saved" : "Connection failed: " + r.error;
    if (r.ok) {                       // like Auday: offer the service's model list
      const m = await api("models");
      let list = $("#modelList");
      if (!list) { list = document.createElement("datalist"); list.id = "modelList"; view.append(list); }
      list.innerHTML = (m.models || []).map(id => `<option value="${esc(id)}">`).join("");
      $('[data-k="model"]').setAttribute("list", "modelList");
      if (m.models && m.models.length) $("#checkResult").textContent += ` · ${m.models.length} models available`;
    }
  };
  $("#openWatchRow").onclick = openWatch;
  renderArchive();
  renderWorkflow();
  $("#voiceRec").onclick = toggleVoiceRecording;
  $("#exportBtn").onclick = exportLibrary;
  if (section === "archive") setTimeout(() => $("#archive").scrollIntoView({ block: "start" }), 50);
}
async function exportLibrary() {
  const data = await api("export");
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], { type: "application/json" }));
  a.download = "library.json"; a.click();
}

// Voiceprint enrolment: one recording covers all three readings.
let voiceRec = null;
async function toggleVoiceRecording() {
  if (voiceRec) { voiceRec.recorder.stop(); return; }
  let stream;
  try { stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: false } }); }
  catch (e) { return toast("Can't use the microphone: " + e.message); }
  const mime = ["audio/webm;codecs=opus", "audio/mp4", "audio/webm"].find(t => MediaRecorder.isTypeSupported(t)) || "";
  const recorder = new MediaRecorder(stream, mime ? { mimeType: mime } : undefined), chunks = [], began = Date.now();
  recorder.ondataavailable = e => e.data.size && chunks.push(e.data);
  recorder.onstop = () => {
    stream.getTracks().forEach(t => t.stop()); clearInterval(voiceRec.timer); voiceRec = null;
    if ($("#voiceRec")) $("#voiceRec").textContent = "Start reading";
    enrollVoice(new Blob(chunks, { type: recorder.mimeType }), recorder.mimeType.includes("mp4") ? "m4a" : "webm");
  };
  recorder.start();
  voiceRec = { recorder, timer: setInterval(() => { const t = $("#voiceTime"); if (t) t.textContent = `${(Date.now() - began) / 1000 | 0} s · tap Done after the three readings`; }, 500) };
  $("#voiceRec").textContent = "Done";
}
async function enrollVoice(blob, ext) {
  toast("Enrolling your voice…", 8000);
  try {
    const r = await api(`voiceprint?ext=${ext}`, { body: blob });
    toast(`Voice enrolled (${r.seconds} s)`); if (route().name === "settings") renderSettings();
  } catch (e) { toast("Voice enrolment failed: " + e.message); }
}

// ---------- status polling ----------
function paintStatus() {
  const st = state.status;
  const pulse = $("#pulse");
  if (pulse && st) { pulse.classList.toggle("busy", !!(st.queue || st.current)); pulse.title = st.current || (st.queue ? `Queue ${st.queue}` : "Idle"); }
  const more = $("#moreDot"); if (more) more.hidden = !(st && st.reviewCount);
  const live = !!state.rec, btn = $("#watchBtn"), dot = $("#watchDot");
  if (btn) btn.classList.toggle("live", live);
  if (dot) dot.hidden = !live;
}
let lastSig = "";
async function poll() {
  try {
    const st = await api("status");
    const mem = await api("memories?status=candidate").catch(() => ({ memories: [] }));
    st.reviewCount = mem.memories.length + st.openReviews;
    state.status = st; state.pipeline = st.pipeline; state.voiceprint = st.voiceprint;
    paintStatus();
    const sig = JSON.stringify([st.counts, st.activity.length && st.activity[st.activity.length - 1]]);
    const busy = !$("#sheet").hidden || document.activeElement && ["TEXTAREA", "INPUT", "SELECT"].includes(document.activeElement.tagName);
    if (sig !== lastSig && lastSig && !busy) {
      const r = route().name;
      if (["days", "hour", "reflection", "memory"].includes(r)) { const y = scrollY; render().then(() => scrollTo(0, y)); }
    }
    lastSig = sig;
  } catch (e) { /* server unreachable (e.g. restarting); try again next round */ }
  setTimeout(poll, 3000);
}
window.addEventListener("beforeunload", e => { if (state.rec) { e.preventDefault(); e.returnValue = ""; } });

api("settings").then(s => (state.settings = s)).catch(() => {}).finally(() => { lastHash = location.hash; render(); });
poll();
