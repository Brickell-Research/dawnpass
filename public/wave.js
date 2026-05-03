// dawnpass · client-side renderer for /data/latest.json
//
// Reads the most recent buoy + marine + tide readings from the shared JSON
// file the Gleam ingest writes, populates the Now card, and renders a
// three-component animated SVG:
//   dominant swell (cyan)    — Hs + Tp
//   mean sea (white@0.4)     — Hs + Tm   (collapses onto swell when Tm absent)
//   wind chop (pink)         — wind_speed_ms (period is a fixed 2s)
//
// Degrades gracefully: missing fields render "—"; missing data file shows a
// status hint; if all wave fields are null, only the mean layer runs as a
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
  if (!r) return setStatus('no buoy reading');

  const picked = pickWaveSource(r, marine);

  els.wave.textContent = picked.heightM != null
    ? `${(picked.heightM * FEET_PER_M).toFixed(1)} ft`
    : '—';

  els.period.textContent = picked.periodS != null
    ? `${picked.periodS.toFixed(0)} s`
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
  // Swell arrows + label rotate with the picked source's wave direction.
  // Wind arrow + label rotate with the buoy's wind direction. Both arrows
  // point TOWARD the source (FROM bearing), matching the cardinal label.
  // The wave metric-tag mirrors the swell cardinal so the now-card has a
  // glance-level direction without depending on map literacy.
  const swellDir = pickWaveDirection(r, marine);
  if (swellDir != null) {
    els.mapSwell.textContent = cardinal(swellDir);
    rotateMapArrow(els.mapSwellArrows, swellDir, SWELL_NATURAL_DEG, 42, 195);
    els.waveTag.textContent = cardinal(swellDir);
  } else {
    els.waveTag.textContent = '';
  }

  if (r.wind_direction_deg != null) {
    els.mapWind.textContent = cardinal(r.wind_direction_deg);
    rotateMapArrow(els.mapWindArrow, r.wind_direction_deg, WIND_NATURAL_DEG, 170, 100);
  }

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

  // === wave-animation mapping (Direction 2: three-component sea state) ===
  //
  // Three superimposed sine layers, each tied to a different aspect of the
  // reading. The space between swell.period_s and mean.period_s is the visible
  // "messiness" of the sea: when Tp ≈ Tm the layers lock in phase (clean
  // groundswell); when they diverge they beat against each other (wind sea).
  //
  //   swell — Hs * 30 px amp (clamp 6..45),   Tp * 30 px λ (clamp 60..400)
  //   mean  — Hs * 18 px amp (clamp 4..30),   Tm * 30 px λ (clamp 60..400)
  //   chop  — ws * 0.75 px amp (clamp 0..6),  fixed 30px λ, fixed 2s period
  //
  // Tm is source-bounded: only honored when the picked source is the buoy
  // (since marine forecast doesn't ship avg_period_s and we don't mix
  // sources). When Tm is unavailable, mean collapses onto swell — three
  // components drop to two visible layers, honestly signalling "less rich
  // data today, no Tp/Tm divergence to show." When wind speed < 3 m/s, the
  // chop layer drops out entirely (no decorative jitter on calm days).
  //
  // The 30× / 18× / 1.5× multipliers were chosen so a typical Gulf day
  // (Hs ≈ 1m, Tp ≈ 6s, ws ≈ 8 m/s) lands mid-frame across all three layers
  // without overlap clipping the viewBox. Numbers are taste, not science.
  if (picked.heightM != null && picked.periodS != null) {
    const Hs = picked.heightM;
    const Tp = picked.periodS;
    const isBuoy = picked.sourceLabel.startsWith('buoy');
    const Tm = (isBuoy && r.avg_period_s != null) ? r.avg_period_s : Tp;

    wave.swell.amp      = clamp(Hs * 30, 6, 45);
    wave.swell.lambda   = clamp(Tp * 30, 60, 400);
    wave.swell.period_s = Tp;

    wave.mean.amp       = clamp(Hs * 18, 4, 30);
    wave.mean.lambda    = clamp(Tm * 30, 60, 400);
    wave.mean.period_s  = Tm;

    const ws = r.wind_speed_ms ?? 0;
    wave.chop.amp = ws > 3 ? clamp(ws * 0.75, 0, 6) : 0;
  } else {
    // All wave fields null → breath fallback on mean only.
    wave.swell.amp     = 0;
    wave.chop.amp      = 0;
    wave.mean.lambda   = 200;
    wave.mean.period_s = null;
    // mean.amp is owned by the breath loop in this mode; don't fight it
  }

  startMotion();
}

// === wave-source picking ===
//
// Choose which source feeds the wave SVG and the wave/period cells.
//
// Inputs:
//   buoy   — latest NDBC reading. Sensor truth, but routinely null on wave
//            fields in calm Gulf conditions (42036 is notorious).
//   marine — latest Open-Meteo Marine reading. Forecast model, not sensor;
//            never silent for valid coordinates, less authoritative.
//
// Output: { heightM, periodS, sourceLabel }.
//
// Rule: buoy when both Hs and Tp are present, else marine when both are
// present, else nothing. All-or-nothing per source — we never mix Hs from
// one with Tp from another. Mixed-source reads are confusing; per-field
// provenance is a future refactor (the Conditions step).
//
// sourceLabel is internal-only today. The UI shows the spot name, not the
// data source. Step 6 surfaces provenance more carefully.
function pickWaveSource(buoy, marine) {
  if (buoy && buoy.wave_height_m != null && buoy.dominant_period_s != null) {
    return {
      heightM: buoy.wave_height_m,
      periodS: buoy.dominant_period_s,
      sourceLabel: `buoy ${buoy.station}`,
    };
  }
  if (marine && marine.wave_height_m != null && marine.wave_period_s != null) {
    return {
      heightM: marine.wave_height_m,
      periodS: marine.wave_period_s,
      sourceLabel: 'marine · pag',
    };
  }
  return {
    heightM: null,
    periodS: null,
    sourceLabel: buoy ? `buoy ${buoy.station}` : '—',
  };
}

// Same source-precedence as pickWaveSource, but only for direction.
// Buoy wave direction first (sensor truth), then marine forecast,
// else null (caller keeps the static placeholder).
function pickWaveDirection(buoy, marine) {
  if (buoy && buoy.mean_wave_direction_deg != null) return buoy.mean_wave_direction_deg;
  if (marine && marine.wave_direction_deg != null) return marine.wave_direction_deg;
  return null;
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

function clamp(v, lo, hi) {
  return Math.max(lo, Math.min(hi, v));
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

load();
startMotion();

// Re-evaluate motion mode if the OS reduced-motion preference toggles live.
window.matchMedia('(prefers-reduced-motion: reduce)')
  .addEventListener('change', startMotion);
