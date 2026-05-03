// dawnpass · client-side renderer for /data/latest.json
//
// Reads the buoy + tide + marine + pre-computed wave block from the shared
// JSON the Gleam ingest writes, populates the Now card, and animates a
// three-component SVG (cyan swell + white mean + pink chop).
//
// The wave-layer math (source-precedence, clamps, Tm fallback, chop wind
// threshold) lives in src/dawnpass/wave_spec.gleam — this file is purely
// a renderer. The JSON shape it expects is documented in wave_spec.encode.
//
// Degrades gracefully: missing fields render "—"; missing data file shows a
// status hint; if the wave block is silent, only the mean layer runs as a
// slow breath + drift ("the buoy is silent but we're listening").

const KNOTS_PER_MS = 1.94384;
const FEET_PER_M = 3.28084;

const els = {
  wave:      document.getElementById('m-wave'),
  period:    document.getElementById('m-period'),
  wind:      document.getElementById('m-wind'),
  tide:      document.getElementById('m-tide'),
  updated:   document.getElementById('now-updated'),
  swell:        document.getElementById('wave-swell'),
  mean:         document.getElementById('wave-mean'),
  chop:         document.getElementById('wave-chop'),
  card:         document.querySelector('.now'),
  stalePill:    document.getElementById('stale-pill'),
  mapSwell:        document.getElementById('map-swell'),
  mapSwellArrows:  document.getElementById('map-swell-arrows'),
  mapWind:         document.getElementById('map-wind'),
  mapWindArrow:    document.getElementById('map-wind-arrow'),
  windTag:         document.getElementById('m-wind-tag'),
  waveTag:         document.getElementById('m-wave-tag'),
  outlookGrid:     document.getElementById('outlook-grid'),
  nowScore:        document.getElementById('now-score'),
  nowScoreValue:   document.getElementById('now-score-value'),
  nowScoreVerdict: document.getElementById('now-score-verdict'),
  windowWhen:      document.getElementById('window-when'),
  windowMeta:      document.getElementById('window-meta'),
};

// Beach orientation for wind-quality classification. PAG faces west, so
// the beach normal (perpendicular pointing to open water) is 270°. Moves
// to spot config when spots/<spot>.json lands.
const PAG_BEACH_NORMAL_DEG = 270;

// Map directional indicator constants. Arrows point TOWARD the source
// (FROM direction) — i.e. the same bearing the cardinal label names. So
// "wind NNE" = arrow pointing NNE, intuitively reading "the wind is
// coming from up there". Rotation math:
//   rotation = fromDeg - <natural compass angle of the arrow as drawn>
//
// SWELL_NATURAL_DEG: the three diagonal swell arrows are drawn pointing
//   NE (compass ~56°). For wave from 225° (SW), arrows rotate to point SW.
// WIND_NATURAL_DEG: the wind arrow is drawn horizontally pointing East
//   (compass 90°).
const SWELL_NATURAL_DEG = 56;
const WIND_NATURAL_DEG = 90;

const STALE_THRESHOLD_MS = 2 * 60 * 60 * 1000;  // 2 hours

// Wave animation state — three superimposed components, each with its own
// amplitude / wavelength (px in viewBox) / period (real seconds) / phase.
// render() updates the numeric fields on each data load; startMotion() drives
// the master tick that advances each layer's phase.
//
// `mean.period_s` is the canonical "data present" signal — when null, we're
// in breath fallback (mean layer only) and the other two layers stay at amp=0.
const wave = {
  swell: { amp: 0, lambda: 200, period_s: null, phase: 0 },
  mean:  { amp: 0, lambda: 200, period_s: null, phase: 0 },
  chop:  { amp: 0, lambda: 30,  period_s: 2,    phase: 0 },
};

async function load() {
  try {
    const res = await fetch('/data/latest.json', { cache: 'no-store' });
    if (!res.ok) return setStatus('no data file yet');
    const data = await res.json();
    render(data);
  } catch (e) {
    setStatus('fetch failed');
  }
}

function render(data) {
  // JSON shape: { "buoy_<station>": {...}, "tide_<station>": {...}, "marine_<spot>": {...}, ... }
  const buoyKey   = Object.keys(data).find(k => k.startsWith('buoy_'));
  const tideKey   = Object.keys(data).find(k => k.startsWith('tide_'));
  const marineKey = Object.keys(data).find(k => k.startsWith('marine_'));
  const r      = buoyKey   ? data[buoyKey]   : null;
  const tide   = tideKey   ? data[tideKey]   : null;
  const marine = marineKey ? data[marineKey] : null;
  const w      = data.wave ?? null;  // pre-computed by wave_spec.gleam
  if (!r) return setStatus('no buoy reading');

  els.wave.textContent = w?.height_m != null
    ? `${(w.height_m * FEET_PER_M).toFixed(1)} ft`
    : '—';

  els.period.textContent = w?.period_s != null
    ? `${w.period_s.toFixed(0)} s`
    : '—';

  els.wind.textContent = formatWind(r.wind_speed_ms, r.wind_direction_deg);

  // Wind quality badge — offshore (clean) / onshore (blown out) / sideshore.
  if (r.wind_direction_deg != null) {
    const q = windQuality(r.wind_direction_deg, PAG_BEACH_NORMAL_DEG);
    els.windTag.textContent = q;
    els.windTag.setAttribute('data-quality', q);
  } else {
    els.windTag.textContent = '';
    els.windTag.removeAttribute('data-quality');
  }

  renderTide(els.tide, tide);

  // === Live map directional indicators (notebook chart) ===
  // Swell arrows + label rotate with the wave block's direction (which uses
  // the same source-precedence as the wave height/period: buoy first, marine
  // fallback). Wind arrow + label rotate with the buoy's wind direction.
  // Both arrows point TOWARD the source (FROM bearing).
  const swellDir = w?.direction_deg ?? null;
  if (swellDir != null) {
    els.mapSwell.textContent = cardinal(swellDir);
    rotateMapArrow(els.mapSwellArrows, swellDir, SWELL_NATURAL_DEG, 42, 195);
    els.waveTag.textContent = `from ${cardinal(swellDir)}`;
  } else {
    els.waveTag.textContent = '';
  }

  if (r.wind_direction_deg != null) {
    els.mapWind.textContent = cardinal(r.wind_direction_deg);
    rotateMapArrow(els.mapWindArrow, r.wind_direction_deg, WIND_NATURAL_DEG, 170, 100);
  }

  // 3-day outlook strip — wave + tide highs/lows.
  renderOutlook(els.outlookGrid, marine?.forecast ?? [], tide);

  // Recommendation engine output (computed by src/dawnpass/score/orchestrator.gleam):
  //   data.score.now            — current Conditions score (0-10 + verdict + sub-scores + vetoes)
  //   data.score.windows        — hysteresis-detected rideable windows in the next 72h
  //   data.score.best_overall   — highest-composite window across the horizon
  const scoreBlock = data.score ?? null;
  renderNowScore(scoreBlock?.now);
  renderNextWindow(scoreBlock?.best_overall);

  // Spot identity now lives in the now-map illustration; no text pill.
  els.updated.textContent = r.observed_at_utc
    ? `updated ${formatTimestamp(r.observed_at_utc)}`
    : 'no timestamp';

  // Buoy older than STALE_THRESHOLD_MS (or unknown) marks the card stale.
  const obs = r.observed_at_utc ? new Date(r.observed_at_utc) : null;
  const stale = !obs || isNaN(obs.getTime())
    || (Date.now() - obs.getTime()) > STALE_THRESHOLD_MS;
  if (stale) {
    els.card.setAttribute('data-stale', '');
    els.stalePill.removeAttribute('hidden');
  } else {
    els.card.removeAttribute('data-stale');
    els.stalePill.setAttribute('hidden', '');
  }

  // Apply pre-computed wave layers. The math layer (clamps, source-
  // precedence, Tm fallback, chop wind threshold) lives in
  // src/dawnpass/wave_spec.gleam — this is just the copy.
  applyLayers(w);

  startMotion();
}

// Copy the server-computed layer params from the JSON `wave` block into
// the local animation state. Silent state (or missing block) → breath
// fallback (mean layer only).
function applyLayers(w) {
  if (!w || w.source === 'silent') {
    wave.swell.amp     = 0;
    wave.chop.amp      = 0;
    wave.mean.lambda   = 200;
    wave.mean.period_s = null;
    // mean.amp is owned by the breath loop in this mode; don't fight it
    return;
  }
  wave.swell.amp      = w.swell.amp;
  wave.swell.lambda   = w.swell.lambda;
  wave.swell.period_s = w.swell.period_s;

  wave.mean.amp       = w.mean.amp;
  wave.mean.lambda    = w.mean.lambda;
  wave.mean.period_s  = w.mean.period_s;

  wave.chop.amp       = w.chop.amp;
  wave.chop.lambda    = w.chop.lambda;
  wave.chop.period_s  = w.chop.period_s;
}

// Classify a wind FROM-bearing relative to the spot's beach normal as
// offshore / onshore / sideshore. The beach normal is the perpendicular
// pointing OUT to open water — for PAG (west-facing), 270°. Wind from
// the same bearing as the normal (e.g. wind FROM the W onto a W-facing
// beach) is onshore; wind from the opposite (FROM the E) is offshore.
//
// Threshold is ±45° around each axis: ≤45° from the offshore direction →
// 'offshore'; ≥135° from offshore → 'onshore'; otherwise 'sideshore'.
function windQuality(fromDeg, beachNormalDeg) {
  const offshoreDeg = (beachNormalDeg + 180) % 360;
  // Signed angular distance from offshore direction, normalised to [-180, +180].
  const diff = ((fromDeg - offshoreDeg + 540) % 360) - 180;
  const abs = Math.abs(diff);
  if (abs <= 45)  return 'offshore';
  if (abs >= 135) return 'onshore';
  return 'sideshore';
}

// Rotate a map arrow group so it points TOWARD the source — `fromDeg` is
// the bearing the wave/wind is coming from, and that's where we want the
// arrow to visually point. naturalDeg is the compass angle the arrow
// already points at when the rotation is 0. cx/cy is the rotation center.
function rotateMapArrow(group, fromDeg, naturalDeg, cx, cy) {
  if (!group) return;
  const rotation = fromDeg - naturalDeg;
  group.setAttribute('transform', `rotate(${rotation.toFixed(1)} ${cx} ${cy})`);
}

function setStatus(msg) {
  els.updated.textContent = msg;
}

function formatWind(ms, deg) {
  if (ms == null && deg == null) return '—';
  const kt = ms != null ? `${(ms * KNOTS_PER_MS).toFixed(0)} kt` : '?';
  const dir = deg != null ? cardinal(deg) : '';
  return `${dir} ${kt}`.trim();
}

function cardinal(deg) {
  const dirs = ['N','NNE','NE','ENE','E','ESE','SE','SSE',
                'S','SSW','SW','WSW','W','WNW','NW','NNW'];
  return dirs[Math.round(deg / 22.5) % 16];
}

// Both formatters render in the viewer's local timezone via Intl. Server-side
// data is always UTC ISO; the conversion happens in the browser at render time.
const TIME_OPTS = { hour: '2-digit', minute: '2-digit', hour12: false, timeZoneName: 'short' };
const DATE_OPTS = { month: 'long', day: 'numeric', year: 'numeric' };

function formatTimestamp(iso) {
  const d = new Date(iso);
  if (isNaN(d.getTime())) return iso;
  return `${d.toLocaleTimeString([], TIME_OPTS)} · ${d.toLocaleDateString([], DATE_OPTS)}`;
}

function formatTimeOnly(iso) {
  const d = new Date(iso);
  if (isNaN(d.getTime())) return iso;
  return d.toLocaleTimeString([], TIME_OPTS);
}

// Render the tide line as separate `·`-joined chunks so each chunk wraps
// as a unit on narrow viewports — never mid-string ("high at" / "12:35 MDT").
function renderTide(el, t) {
  el.textContent = '';
  if (!t) { el.textContent = '—'; return; }
  const parts = [];
  if (t.height_ft != null) parts.push(`${t.height_ft.toFixed(1)} ft`);
  if (t.trend) parts.push(t.trend);
  if (t.next_event) parts.push(`${t.next_event.kind} at ${formatTimeOnly(t.next_event.at_utc)}`);
  if (parts.length === 0) { el.textContent = '—'; return; }
  parts.forEach((text, i) => {
    if (i > 0) el.appendChild(document.createTextNode(' · '));
    const span = document.createElement('span');
    span.className = 'tide-chunk';
    span.textContent = text;
    el.appendChild(span);
  });
}

// === Motion ===
//
// Two modes, picked by render() via wave.mean.period_s:
//   step-tick — single master 1Hz interval. Each tick advances every active
//               layer's phase by 2π/period_s. Different layer periods produce
//               visibly different drift speeds — that relative drift is the
//               "messiness" reveal between swell and mean.
//   breath    — only the mean layer renders. Slow amplitude oscillation +
//               drift. Reads as quietly alive when buoy + marine are silent.
//
// startMotion() is idempotent: render() calls it on every data load.

const STEP_HZ = 1;
const BREATH_PERIOD_S = 10;
const BREATH_AMP_MIN = 4;
const BREATH_AMP_MAX = 7;
const BREATH_DRIFT_PERIOD_S = 30;  // one wavelength per 30s — slow ambient motion

let stepIntervalId = null;
let breathRafId = null;

function startMotion() {
  stopMotion();
  // Honor OS-level reduced-motion preference: render one static frame, no loop.
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    drawAll();
    return;
  }
  if (wave.mean.period_s != null) {
    drawAll();
    stepIntervalId = setInterval(() => {
      for (const layer of [wave.swell, wave.mean, wave.chop]) {
        if (layer.period_s != null && layer.amp > 0) {
          layer.phase += (2 * Math.PI) / layer.period_s;
        }
      }
      drawAll();
    }, 1000 / STEP_HZ);
  } else {
    drawAll();  // clear any stale paths from a prior step-tick mode immediately
    const origin = performance.now();
    let lastFrame = origin;
    const loop = (now) => {
      const dt = (now - lastFrame) / 1000;
      lastFrame = now;
      const t = (now - origin) / 1000;
      const mid = (BREATH_AMP_MIN + BREATH_AMP_MAX) / 2;
      const swing = (BREATH_AMP_MAX - BREATH_AMP_MIN) / 2;
      wave.mean.amp = mid + swing * Math.sin((2 * Math.PI * t) / BREATH_PERIOD_S);
      wave.mean.phase += (2 * Math.PI * dt) / BREATH_DRIFT_PERIOD_S;
      drawAll();
      breathRafId = requestAnimationFrame(loop);
    };
    breathRafId = requestAnimationFrame(loop);
  }
}

function stopMotion() {
  if (stepIntervalId) { clearInterval(stepIntervalId); stepIntervalId = null; }
  if (breathRafId)    { cancelAnimationFrame(breathRafId); breathRafId = null; }
}

function drawAll() {
  drawLayer(els.swell, wave.swell);
  // Skip mean when it would just be a smaller copy of swell (same period →
  // same shape, drawn under swell, pure visual noise). Honest about provenance:
  // a marine-source day with no Tm shows as swell + chop, not three-component.
  const meanCollapsed = wave.mean.period_s === wave.swell.period_s
    && wave.mean.period_s != null;
  if (meanCollapsed) {
    els.mean.setAttribute('d', '');
  } else {
    drawLayer(els.mean, wave.mean);
  }
  drawLayer(els.chop, wave.chop);
}

function drawLayer(pathEl, layer) {
  if (layer.amp <= 0) {
    pathEl.setAttribute('d', '');
    return;
  }
  const W = 800, H = 100, cy = H / 2;
  const samples = 200;
  let d = `M0,${cy}`;
  for (let i = 1; i <= samples; i++) {
    const x = (i / samples) * W;
    const y = cy - layer.amp * Math.sin(
      (x / layer.lambda) * Math.PI * 2 - layer.phase
    );
    d += ` L${x.toFixed(1)},${y.toFixed(2)}`;
  }
  pathEl.setAttribute('d', d);
}

// === 3-day outlook ===
//
// Renders the marine forecast as 3 daily summary cards into `gridEl`.
// Days are bucketed by the *user's local* day boundary (so "Sun" means
// "Sunday in your timezone" — most of UTC Sunday plus a few hours of
// UTC Monday for US timezones). Past hours (forecast.at_utc < now) are
// dropped so the first card is always "from this hour onward."
//
// Per-day stats:
//   wave    — min..max wave_height_m converted to ft
//   period  — median wave_period_s rounded to seconds
//   swell   — circular-mean wave_direction_deg as a cardinal (handles
//             the 0/360 wrap-around correctly)
function renderOutlook(gridEl, forecastHours, tide) {
  if (!gridEl) return;
  gridEl.replaceChildren();

  const days = groupForecastByLocalDay(forecastHours, 3);
  if (days.length === 0) {
    const empty = document.createElement('p');
    empty.className = 'outlook-empty';
    empty.textContent = 'no forecast data';
    gridEl.appendChild(empty);
    return;
  }

  for (const day of days) {
    gridEl.appendChild(buildDayCard(day, tide));
  }
}

function groupForecastByLocalDay(forecastHours, maxDays) {
  const now = Date.now();
  const groups = new Map();

  for (const hour of forecastHours) {
    const d = new Date(hour.at_utc);
    if (isNaN(d.getTime())) continue;
    if (d.getTime() < now) continue;

    const key = `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
    if (!groups.has(key)) {
      if (groups.size >= maxDays) continue;
      groups.set(key, {
        label: d.toLocaleDateString(undefined, { weekday: 'short' }),
        date: d,
        hours: [],
      });
    }
    groups.get(key).hours.push(hour);
  }

  return Array.from(groups.values()).map(g => ({ ...g, ...dayStats(g.hours) }));
}

function dayStats(hours) {
  const heights = hours.map(h => h.wave_height_m).filter(v => v != null);
  const periods = hours.map(h => h.wave_period_s).filter(v => v != null);
  const dirs    = hours.map(h => h.wave_direction_deg).filter(v => v != null);

  return {
    minHeight:    heights.length ? Math.min(...heights) : null,
    maxHeight:    heights.length ? Math.max(...heights) : null,
    medianPeriod: periods.length ? medianOf(periods) : null,
    dominantDir:  dirs.length    ? circularMean(dirs) : null,
  };
}

function medianOf(xs) {
  const sorted = [...xs].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

// Mean of compass bearings using vector summation. Plain arithmetic mean
// fails at the 0/360 wrap-around (mean of [355, 5] would be 180, not 0).
function circularMean(degrees) {
  const sumSin = degrees.reduce((s, deg) => s + Math.sin(deg * Math.PI / 180), 0);
  const sumCos = degrees.reduce((s, deg) => s + Math.cos(deg * Math.PI / 180), 0);
  let mean = Math.atan2(sumSin, sumCos) * 180 / Math.PI;
  if (mean < 0) mean += 360;
  return mean;
}

function buildDayCard(day, tide) {
  const card = document.createElement('article');
  card.className = 'outlook-day';

  const name = document.createElement('h3');
  name.className = 'outlook-day-name';
  name.textContent = day.label;
  card.appendChild(name);

  card.appendChild(outlookRow('wave',   formatWaveRange(day)));
  card.appendChild(outlookRow('period', formatOutlookPeriod(day)));
  card.appendChild(outlookRow('swell',  formatOutlookSwell(day)));
  card.appendChild(buildTideRow(day, tide));
  return card;
}

// Build the tide row as a vertical stack of color-coded H/L events.
// Each event renders as "<colored kind> HH:MM<a|p>" — easier to scan
// than the previous joined " · " string when there are 3-4 events.
function buildTideRow(day, tide) {
  const row = document.createElement('div');
  row.className = 'outlook-row';

  const label = document.createElement('span');
  label.className = 'outlook-label';
  label.textContent = 'tide';
  row.appendChild(label);

  const events = tide && Array.isArray(tide.upcoming)
    ? tide.upcoming.filter(e => sameLocalDay(new Date(e.at_utc), day.date))
    : [];

  if (events.length === 0) {
    const empty = document.createElement('span');
    empty.className = 'outlook-value';
    empty.textContent = '—';
    row.appendChild(empty);
    return row;
  }

  const stack = document.createElement('div');
  stack.className = 'outlook-tide-stack';
  for (const e of events) {
    const ev = document.createElement('div');
    ev.className = 'tide-event';

    const kindCh = e.kind === 'high' ? 'H' : 'L';
    const kindEl = document.createElement('span');
    kindEl.className = 'tide-event-kind';
    kindEl.setAttribute('data-kind', kindCh);
    kindEl.textContent = kindCh;
    ev.appendChild(kindEl);

    ev.appendChild(document.createTextNode(localTime(e.at_utc)));
    stack.appendChild(ev);
  }
  row.appendChild(stack);
  return row;
}

function outlookRow(label, value, valueClass = 'outlook-value') {
  const row = document.createElement('div');
  row.className = 'outlook-row';

  const l = document.createElement('span');
  l.className = 'outlook-label';
  l.textContent = label;
  row.appendChild(l);

  const v = document.createElement('span');
  v.className = valueClass;
  v.textContent = value;
  row.appendChild(v);

  return row;
}

// Pull tide hi/lo events that fall on the same local day as `day.date`.
// Returns a compact string like "H 9:14a · L 12:05p · H 6:35p" — or "—".
function formatDayTide(day, tide) {
  if (!tide || !Array.isArray(tide.upcoming) || tide.upcoming.length === 0) return '—';
  const events = tide.upcoming.filter(e => sameLocalDay(new Date(e.at_utc), day.date));
  if (events.length === 0) return '—';
  return events.map(e => {
    const sym = e.kind === 'high' ? 'H' : 'L';
    return `${sym} ${localTime(e.at_utc)}`;
  }).join(' · ');
}

function sameLocalDay(a, b) {
  return a.getFullYear() === b.getFullYear()
      && a.getMonth() === b.getMonth()
      && a.getDate() === b.getDate();
}

// "2026-05-04T02:40:00Z" → "10:40p" in the user's local time.
function localTime(iso) {
  const d = new Date(iso);
  if (isNaN(d.getTime())) return '';
  const h = d.getHours();
  const mm = String(d.getMinutes()).padStart(2, '0');
  const ampm = h >= 12 ? 'p' : 'a';
  const h12 = h % 12 === 0 ? 12 : h % 12;
  return `${h12}:${mm}${ampm}`;
}

function formatWaveRange(day) {
  if (day.minHeight == null || day.maxHeight == null) return '—';
  const minFt = day.minHeight * FEET_PER_M;
  const maxFt = day.maxHeight * FEET_PER_M;
  if (Math.abs(maxFt - minFt) < 0.15) return `${maxFt.toFixed(1)} ft`;
  return `${minFt.toFixed(1)}–${maxFt.toFixed(1)} ft`;
}

function formatOutlookPeriod(day) {
  return day.medianPeriod != null ? `${day.medianPeriod.toFixed(0)} s` : '—';
}

function formatOutlookSwell(day) {
  return day.dominantDir != null ? cardinal(day.dominantDir) : '—';
}

// === Recommendation engine surface ===
//
// The Gleam scoring orchestrator emits a `score` block with `now` (current
// Conditions score) and `best_overall` (highest-composite rideable window
// in the 72h horizon). These render into the Now header and the dedicated
// "next window" section. Empty windows is a first-class state — for PAG
// it is the honest answer most days.

function renderNowScore(now) {
  if (!now) {
    els.nowScore.setAttribute('hidden', '');
    return;
  }
  els.nowScore.removeAttribute('hidden');
  els.nowScoreValue.textContent = now.overall.toFixed(1);
  els.nowScoreVerdict.textContent = now.verdict ?? '';
  if (now.verdict) {
    els.nowScoreVerdict.setAttribute('data-band', now.verdict);
  } else {
    els.nowScoreVerdict.removeAttribute('data-band');
  }
}

function renderNextWindow(w) {
  if (!w) {
    els.windowWhen.textContent = 'nothing in the next 72 hours';
    els.windowWhen.setAttribute('data-empty', '');
    els.windowMeta.textContent = '';
    return;
  }
  els.windowWhen.removeAttribute('data-empty');
  els.windowWhen.textContent = formatWindowRange(w.starts_at, w.ends_at);
  els.windowMeta.textContent = formatWindowMeta(w);
}

function formatWindowMeta(w) {
  const peak = `peak ${w.peak_score.toFixed(1)}/10`;
  // horizon_hours_out=0 means the window has already started. Distinguish
  // "in progress" from "just about to start".
  const endsTs = new Date(w.ends_at).getTime();
  const horizon =
    w.horizon_hours_out === 0
      ? endsTs > Date.now()
        ? 'happening now'
        : 'just ended'
      : `${w.horizon_hours_out}h out`;
  const conf = `${w.confidence} confidence`;
  return `${peak} · ${horizon} · ${conf}`;
}

function formatWindowRange(startIso, endIso) {
  const a = new Date(startIso);
  const b = new Date(endIso);
  if (isNaN(a.getTime()) || isNaN(b.getTime())) return '';
  const aDay = a.toLocaleDateString(undefined, { weekday: 'short' });
  const bDay = b.toLocaleDateString(undefined, { weekday: 'short' });
  const aTime = formatLocalShortTime(a);
  const bTime = formatLocalShortTime(b);
  // Same local day → "Sun 7am-11am"; spans midnight → "Sun 10pm – Mon 6am".
  return a.getDate() === b.getDate() && a.getMonth() === b.getMonth()
    ? `${aDay} ${aTime}-${bTime}`
    : `${aDay} ${aTime} – ${bDay} ${bTime}`;
}

function formatLocalShortTime(d) {
  const h = d.getHours();
  const m = d.getMinutes();
  const ampm = h >= 12 ? 'pm' : 'am';
  const h12 = h % 12 === 0 ? 12 : h % 12;
  return m === 0
    ? `${h12}${ampm}`
    : `${h12}:${String(m).padStart(2, '0')}${ampm}`;
}

load();
startMotion();

// Re-evaluate motion mode if the OS reduced-motion preference toggles live.
window.matchMedia('(prefers-reduced-motion: reduce)')
  .addEventListener('change', startMotion);
