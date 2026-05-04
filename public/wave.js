// dawnpass · client-side renderer for /data/latest.json
//
// Reads the buoy + tide + per-spot blocks from the shared JSON the Gleam
// ingest writes, populates each spot's Now card, and animates each spot's
// three-component SVG (cyan swell + white mean + pink chop).
//
// Per-spot architecture: every <article class="spot" data-spot="..."> on
// the page binds its own element handles + its own wave-layer state.
// Source-precedence math (wave_spec.gleam) and scoring math (score/) live
// in Gleam — this file is purely a renderer.
//
// JSON shape it expects:
//   { "buoy_<station>": {...},
//     "spots": { "<slug>": { name, latitude, longitude,
//                            tide, marine, wind, wave, score }, ... } }
//
// Degrades gracefully: missing fields render "—"; missing spots in the
// JSON leave their cards in their initial empty state.

const KNOTS_PER_MS = 1.94384;
const FEET_PER_M = 3.28084;

// Beach orientation per spot. Drives the offshore/onshore/sideshore tag
// next to the wind metric. Hardcoded here (rather than read from the JSON
// per spot) because it's a UI display concern — the math layer's
// scoring already accounts for it via spot_config.beach_normal_deg.
const SPOT_BEACH_NORMALS = {
  pag: 270,
  venice_south: 250,
};

// Map directional indicator constants. Arrows point TOWARD the source
// (FROM direction). Rotation:  rotation = fromDeg - <natural compass angle>.
const SWELL_NATURAL_DEG = 56;
const WIND_NATURAL_DEG = 90;

const STALE_THRESHOLD_MS = 2 * 60 * 60 * 1000;

const C_TO_F_OFFSET = 32;
const C_TO_F_MULT = 9 / 5;
function celsiusToF(c) { return c * C_TO_F_MULT + C_TO_F_OFFSET; }

// Score threshold above which an hour counts as "rideable" (matches the
// "fun-sized" verdict band in spots.gleam).
const RIDEABLE_SCORE_THRESHOLD = 5;

// Mean-vs-swell period gap below which the mean line is visual noise.
const MEAN_DIVERGENCE_THRESHOLD_S = 1.5;

const PRESSURE_TREND_HOURS = 6;
const PRESSURE_TREND_THRESHOLD_HPA = 1.0;

// === Per-spot state ===
//
// Populated at startup from the DOM. Each entry binds one spot's element
// handles and its own wave-layer state. The render() function loops over
// these and writes per-spot data; the animation tick walks them too.

const spots = [];

function bindSpotElements(container) {
  return {
    container,
    wave:           container.querySelector('.m-wave'),
    period:         container.querySelector('.m-period'),
    wind:           container.querySelector('.m-wind'),
    tide:           container.querySelector('.m-tide'),
    updated:        container.querySelector('.now-updated'),
    swell:          container.querySelector('.wave-swell'),
    mean:           container.querySelector('.wave-mean'),
    chop:           container.querySelector('.wave-chop'),
    card:           container.querySelector('.now'),
    stalePill:      container.querySelector('.stale-pill'),
    mapSwell:       container.querySelector('.map-swell'),
    mapSwellArrows: container.querySelector('.map-swell-arrows'),
    mapWind:        container.querySelector('.map-wind'),
    mapWindArrow:   container.querySelector('.map-wind-arrow'),
    windTag:        container.querySelector('.m-wind-tag'),
    waveTag:        container.querySelector('.m-wave-tag'),
    outlookGrid:    container.querySelector('.outlook-grid'),
    nowScore:       container.querySelector('.now-score'),
    nowScoreValue:  container.querySelector('.now-score-value'),
    nowScoreVerdict:container.querySelector('.now-score-verdict'),
    windowWhen:     container.querySelector('.window-when'),
    windowMeta:     container.querySelector('.window-meta'),
    mapAirTemp:     container.querySelector('.map-air-temp'),
    mapWaterTemp:   container.querySelector('.map-water-temp'),
    mapPressure:    container.querySelector('.map-pressure'),
    meanLabel:      container.querySelector('.wave-mean-label'),
  };
}

function initSpots() {
  for (const article of document.querySelectorAll('.spot')) {
    const slug = article.dataset.spot;
    spots.push({
      slug,
      els: bindSpotElements(article),
      beachNormal: SPOT_BEACH_NORMALS[slug] ?? 270,
      wave: {
        swell: { amp: 0, lambda: 200, period_s: null, phase: 0 },
        mean:  { amp: 0, lambda: 200, period_s: null, phase: 0 },
        chop:  { amp: 0, lambda: 30,  period_s: 2,    phase: 0 },
      },
      motionMode: 'breath',
    });
  }
}

// === Data load ===

async function load() {
  try {
    const res = await fetch('/data/latest.json', { cache: 'no-store' });
    if (!res.ok) return setStatusAll('no data file yet');
    const data = await res.json();
    render(data);
  } catch (e) {
    setStatusAll('fetch failed');
  }
}

function setStatusAll(msg) {
  for (const s of spots) {
    if (s.els.updated) s.els.updated.textContent = msg;
  }
}

function render(data) {
  // Shared source at top level (buoy is regional). Per-spot blocks under
  // data.spots.<slug> — including tide, since Gulf-coast tides phase by
  // tens of minutes across even ~50mi of latitude.
  const buoyKey = Object.keys(data).find(k => k.startsWith('buoy_'));
  const r       = buoyKey ? data[buoyKey] : null;
  const spotsData = data.spots ?? {};

  for (const s of spots) {
    const spotData = spotsData[s.slug];
    if (spotData) {
      renderSpot(s, spotData, r);
    }
  }

  startMotion();
}

function renderSpot(s, spotData, r) {
  const els = s.els;
  const w         = spotData.wave ?? null;
  const tide      = spotData.tide ?? null;
  const marine    = spotData.marine ?? null;
  const windBlock = spotData.wind ?? null;
  const scoreBlock = spotData.score ?? null;

  // Wind: prefer buoy's observed values, fall back to per-spot wind block.
  const windSpeedMs = r?.wind_speed_ms ?? windBlock?.wind_speed_ms ?? null;
  const windDirDeg  = r?.wind_direction_deg ?? windBlock?.wind_direction_deg ?? null;

  els.wave.textContent = w?.height_m != null
    ? `${(w.height_m * FEET_PER_M).toFixed(1)} ft`
    : '—';

  els.period.textContent = w?.period_s != null
    ? `${w.period_s.toFixed(0)} s`
    : '—';

  els.wind.textContent = formatWind(windSpeedMs, windDirDeg);

  if (windDirDeg != null) {
    const q = windQuality(windDirDeg, s.beachNormal);
    els.windTag.textContent = q;
    els.windTag.setAttribute('data-quality', q);
  } else {
    els.windTag.textContent = '';
    els.windTag.removeAttribute('data-quality');
  }

  renderTide(els.tide, tide);

  // Map directional indicators (notebook chart).
  const swellDir = w?.direction_deg ?? null;
  if (swellDir != null) {
    if (els.mapSwell) els.mapSwell.textContent = cardinal(swellDir);
    if (els.mapSwellArrows) {
      rotateMapArrowGroup(els.mapSwellArrows, swellDir, SWELL_NATURAL_DEG);
    }
    els.waveTag.textContent = `from ${cardinal(swellDir)}`;
  } else {
    els.waveTag.textContent = '';
  }

  if (windDirDeg != null) {
    if (els.mapWind) els.mapWind.textContent = cardinal(windDirDeg);
    if (els.mapWindArrow) {
      rotateMapArrowGroup(els.mapWindArrow, windDirDeg, WIND_NATURAL_DEG);
    }
  }

  if (els.mapAirTemp) {
    els.mapAirTemp.textContent = windBlock?.air_temp_c != null
      ? `${celsiusToF(windBlock.air_temp_c).toFixed(0)}°F`
      : '—';
  }
  if (els.mapWaterTemp) {
    const wtmpC = r?.wtmp_c ?? marine?.sst_c ?? null;
    els.mapWaterTemp.textContent =
      wtmpC != null ? `${celsiusToF(wtmpC).toFixed(0)}°F` : '—';
  }
  if (els.mapPressure) {
    const pressureNow = windBlock?.pressure_hpa ?? null;
    const arrow = pressureTrendArrow(windBlock);
    els.mapPressure.textContent =
      pressureNow != null ? `${pressureNow.toFixed(0)} ${arrow}`.trim() : '—';
  }

  // 5-day outlook strip.
  renderOutlook(
    els.outlookGrid,
    marine?.forecast ?? [],
    tide,
    scoreBlock?.forecast ?? [],
  );

  // Score + next window.
  renderNowScore(els, scoreBlock?.now);
  renderNextWindow(els, scoreBlock?.best_overall);

  // "updated …" stamp uses the freshest available source timestamp.
  const observedIso =
    r?.observed_at_utc
    ?? marine?.observed_at_utc
    ?? windBlock?.observed_at_utc
    ?? tide?.observed_at_utc
    ?? null;
  els.updated.textContent = observedIso
    ? `updated ${formatTimestamp(observedIso)}`
    : 'no timestamp';

  const obs = observedIso ? new Date(observedIso) : null;
  const stale = !obs || isNaN(obs.getTime())
    || (Date.now() - obs.getTime()) > STALE_THRESHOLD_MS;
  if (stale) {
    els.card.setAttribute('data-stale', '');
    els.stalePill.removeAttribute('hidden');
  } else {
    els.card.removeAttribute('data-stale');
    els.stalePill.setAttribute('hidden', '');
  }

  // Apply pre-computed wave layers to this spot's animation state.
  applyLayers(s, w);
}

function applyLayers(s, w) {
  if (!w || w.source === 'silent') {
    s.wave.swell.amp     = 0;
    s.wave.chop.amp      = 0;
    s.wave.mean.lambda   = 200;
    s.wave.mean.period_s = null;
    s.motionMode = 'breath';
    return;
  }
  s.wave.swell.amp      = w.swell.amp;
  s.wave.swell.lambda   = w.swell.lambda;
  s.wave.swell.period_s = w.swell.period_s;
  s.wave.mean.amp       = w.mean.amp;
  s.wave.mean.lambda    = w.mean.lambda;
  s.wave.mean.period_s  = w.mean.period_s;
  s.wave.chop.amp       = w.chop.amp;
  s.wave.chop.lambda    = w.chop.lambda;
  s.wave.chop.period_s  = w.chop.period_s;
  s.motionMode = (s.wave.mean.period_s != null) ? 'step' : 'breath';
}

// === Wind-quality classification ===

function windQuality(fromDeg, beachNormalDeg) {
  const offshoreDeg = (beachNormalDeg + 180) % 360;
  const diff = ((fromDeg - offshoreDeg + 540) % 360) - 180;
  const abs = Math.abs(diff);
  if (abs <= 45)  return 'offshore';
  if (abs >= 135) return 'onshore';
  return 'sideshore';
}

// Rotate a map arrow group so it points TOWARD the source.
//
// PAG and Venice arrow groups have different rotation centres baked into
// their `transform="rotate(0 cx cy)"` attributes (because the chart
// geometries differ), so we re-read the existing centre rather than
// passing it in. Reads the current transform, rebuilds with the new angle.
function rotateMapArrowGroup(group, fromDeg, naturalDeg) {
  const existing = group.getAttribute('transform') || 'rotate(0 0 0)';
  const m = existing.match(/rotate\(\s*[-\d.]+\s+([-\d.]+)\s+([-\d.]+)\s*\)/);
  const cx = m ? parseFloat(m[1]) : 0;
  const cy = m ? parseFloat(m[2]) : 0;
  const rotation = fromDeg - naturalDeg;
  group.setAttribute('transform', `rotate(${rotation.toFixed(1)} ${cx} ${cy})`);
}

// === Helpers ===

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
// One master interval drives step-tick mode (data present); one master RAF
// loop drives breath fallback mode (data silent). Both walk all spots on
// each tick — every spot has its own wave state and motionMode. A spot in
// step mode advances its phase by 2π/period_s per second; a spot in breath
// mode oscillates its mean amp + drifts.

const STEP_HZ = 1;
const BREATH_PERIOD_S = 10;
const BREATH_AMP_MIN = 4;
const BREATH_AMP_MAX = 7;
const BREATH_DRIFT_PERIOD_S = 30;

let stepIntervalId = null;
let breathRafId = null;

function startMotion() {
  stopMotion();
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    drawAllSpots();
    return;
  }

  const stepSpots = spots.filter(s => s.motionMode === 'step');
  const breathSpots = spots.filter(s => s.motionMode === 'breath');

  if (stepSpots.length > 0) {
    drawAllSpots();
    stepIntervalId = setInterval(() => {
      for (const s of stepSpots) {
        for (const layer of [s.wave.swell, s.wave.mean, s.wave.chop]) {
          if (layer.period_s != null && layer.amp > 0) {
            layer.phase += (2 * Math.PI) / layer.period_s;
          }
        }
        drawAllForSpot(s);
      }
    }, 1000 / STEP_HZ);
  }

  if (breathSpots.length > 0) {
    drawAllSpots();
    const origin = performance.now();
    let lastFrame = origin;
    const loop = (now) => {
      const dt = (now - lastFrame) / 1000;
      lastFrame = now;
      const t = (now - origin) / 1000;
      const mid = (BREATH_AMP_MIN + BREATH_AMP_MAX) / 2;
      const swing = (BREATH_AMP_MAX - BREATH_AMP_MIN) / 2;
      for (const s of breathSpots) {
        s.wave.mean.amp = mid + swing * Math.sin((2 * Math.PI * t) / BREATH_PERIOD_S);
        s.wave.mean.phase += (2 * Math.PI * dt) / BREATH_DRIFT_PERIOD_S;
        drawAllForSpot(s);
      }
      breathRafId = requestAnimationFrame(loop);
    };
    breathRafId = requestAnimationFrame(loop);
  }
}

function stopMotion() {
  if (stepIntervalId) { clearInterval(stepIntervalId); stepIntervalId = null; }
  if (breathRafId)    { cancelAnimationFrame(breathRafId); breathRafId = null; }
}

function drawAllSpots() {
  for (const s of spots) drawAllForSpot(s);
}

function drawAllForSpot(s) {
  const els = s.els;
  if (!els.swell || !els.mean || !els.chop) return;

  drawLayer(els.swell, s.wave.swell);

  const meanCollapsed = s.wave.mean.period_s != null
    && s.wave.swell.period_s != null
    && Math.abs(s.wave.mean.period_s - s.wave.swell.period_s) < MEAN_DIVERGENCE_THRESHOLD_S;
  if (meanCollapsed) {
    els.mean.setAttribute('d', '');
  } else {
    drawLayer(els.mean, s.wave.mean);
  }
  if (els.meanLabel) {
    if (meanCollapsed || s.wave.mean.amp <= 0) {
      els.meanLabel.setAttribute('hidden', '');
    } else {
      els.meanLabel.removeAttribute('hidden');
    }
  }

  drawLayer(els.chop, s.wave.chop);
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

// === 5-day outlook ===

function renderOutlook(gridEl, forecastHours, tide, scoreForecast) {
  if (!gridEl) return;
  gridEl.replaceChildren();

  const days = groupForecastByLocalDay(forecastHours, 5);
  if (days.length === 0) {
    const empty = document.createElement('p');
    empty.className = 'outlook-empty';
    empty.textContent = 'no forecast data';
    gridEl.appendChild(empty);
    return;
  }

  const ridableByDay = ridableHoursByLocalDay(scoreForecast);
  days.forEach((day, idx) => {
    const key = localDayKey(day.date);
    const lowConfidence = idx >= 3;
    gridEl.appendChild(
      buildDayCard(day, tide, ridableByDay.get(key) ?? 0, lowConfidence),
    );
  });
}

const RIDEABLE_SCORE_THRESHOLD_FN = () => RIDEABLE_SCORE_THRESHOLD;
function ridableHoursByLocalDay(scoreForecast) {
  const now = Date.now();
  const counts = new Map();
  for (const entry of scoreForecast) {
    const d = new Date(entry.at_utc);
    if (isNaN(d.getTime()) || d.getTime() < now) continue;
    const score = entry.score;
    if (!score || score.overall == null) continue;
    if (score.overall < RIDEABLE_SCORE_THRESHOLD_FN()) continue;
    const key = localDayKey(d);
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return counts;
}

function localDayKey(d) {
  return `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
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
  const dirs    = hours.map(h => h.wave_direction_deg).filter(v => v != null);

  return {
    minHeight:   heights.length ? Math.min(...heights) : null,
    maxHeight:   heights.length ? Math.max(...heights) : null,
    dominantDir: dirs.length ? circularMean(dirs) : null,
  };
}

function circularMean(degrees) {
  const sumSin = degrees.reduce((s, deg) => s + Math.sin(deg * Math.PI / 180), 0);
  const sumCos = degrees.reduce((s, deg) => s + Math.cos(deg * Math.PI / 180), 0);
  let mean = Math.atan2(sumSin, sumCos) * 180 / Math.PI;
  if (mean < 0) mean += 360;
  return mean;
}

function buildDayCard(day, tide, ridableHours, lowConfidence) {
  const card = document.createElement('article');
  card.className = 'outlook-day';
  if (lowConfidence) card.setAttribute('data-confidence', 'low');

  const name = document.createElement('h4');
  name.className = 'outlook-day-name';
  name.textContent = day.label;
  card.appendChild(name);

  if (lowConfidence) {
    const tag = document.createElement('div');
    tag.className = 'outlook-day-tag';
    tag.textContent = 'less certain';
    card.appendChild(tag);
  }

  const ridable = document.createElement('div');
  ridable.className = 'outlook-day-ridable';
  if (ridableHours > 0) {
    ridable.setAttribute('data-state', 'rideable');
    ridable.textContent =
      `${ridableHours} rideable hour${ridableHours === 1 ? '' : 's'}`;
  } else {
    ridable.setAttribute('data-state', 'flat');
    ridable.textContent = 'no rideable hours';
  }
  card.appendChild(ridable);

  card.appendChild(outlookRow('wave',  formatWaveRange(day)));
  card.appendChild(outlookRow('swell', formatOutlookSwell(day)));
  card.appendChild(buildTideRow(day, tide));
  return card;
}

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

function outlookRow(label, value) {
  const row = document.createElement('div');
  row.className = 'outlook-row';

  const l = document.createElement('span');
  l.className = 'outlook-label';
  l.textContent = label;
  row.appendChild(l);

  const v = document.createElement('span');
  v.className = 'outlook-value';
  v.textContent = value;
  row.appendChild(v);

  return row;
}

function sameLocalDay(a, b) {
  return a.getFullYear() === b.getFullYear()
      && a.getMonth() === b.getMonth()
      && a.getDate() === b.getDate();
}

function localTime(iso) {
  const d = new Date(iso);
  if (isNaN(d.getTime())) return '';
  const hh = String(d.getHours()).padStart(2, '0');
  const mm = String(d.getMinutes()).padStart(2, '0');
  return `${hh}:${mm}`;
}

function formatWaveRange(day) {
  if (day.minHeight == null || day.maxHeight == null) return '—';
  const minFt = day.minHeight * FEET_PER_M;
  const maxFt = day.maxHeight * FEET_PER_M;
  if (Math.abs(maxFt - minFt) < 0.15) return `${maxFt.toFixed(1)} ft`;
  return `${minFt.toFixed(1)}–${maxFt.toFixed(1)} ft`;
}

function formatOutlookSwell(day) {
  return day.dominantDir != null ? cardinal(day.dominantDir) : '—';
}

// === Now-card score + next window (per spot) ===

function renderNowScore(els, now) {
  if (!els.nowScore) return;
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

function renderNextWindow(els, w) {
  if (!els.windowWhen) return;
  if (!w) {
    els.windowWhen.textContent = 'nothing in the next 5 days';
    els.windowWhen.setAttribute('data-empty', '');
    if (els.windowMeta) els.windowMeta.textContent = '';
    return;
  }
  els.windowWhen.removeAttribute('data-empty');
  els.windowWhen.textContent = formatWindowRange(w.starts_at, w.ends_at);
  if (els.windowMeta) els.windowMeta.textContent = formatWindowMeta(w);
}

function formatWindowMeta(w) {
  const peak = `peak ${w.peak_score.toFixed(1)}/10`;
  const endsTs = new Date(w.ends_at).getTime();
  const horizon =
    w.horizon_hours_out === 0
      ? endsTs > Date.now() ? 'happening now' : 'just ended'
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
  return a.getDate() === b.getDate() && a.getMonth() === b.getMonth()
    ? `${aDay} ${aTime}-${bTime}`
    : `${aDay} ${aTime} – ${bDay} ${bTime}`;
}

function formatLocalShortTime(d) {
  const hh = String(d.getHours()).padStart(2, '0');
  const mm = String(d.getMinutes()).padStart(2, '0');
  return `${hh}:${mm}`;
}

// === Pressure trend ===

function pressureTrendArrow(windBlock) {
  const now = windBlock?.pressure_hpa;
  if (now == null || !Array.isArray(windBlock?.forecast)) return '';
  const target = Date.now() + PRESSURE_TREND_HOURS * 3600 * 1000;
  const future = windBlock.forecast.find(h => {
    const t = new Date(h.at_utc).getTime();
    return !isNaN(t) && t >= target;
  });
  if (future?.pressure_hpa == null) return '';
  const delta = future.pressure_hpa - now;
  if (delta >  PRESSURE_TREND_THRESHOLD_HPA) return '↑';
  if (delta < -PRESSURE_TREND_THRESHOLD_HPA) return '↓';
  return '→';
}

// === Bootstrap ===

initSpots();
load();
startMotion();

window.matchMedia('(prefers-reduced-motion: reduce)')
  .addEventListener('change', startMotion);
