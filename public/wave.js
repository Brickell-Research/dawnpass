// dawnpass · client-side renderer for /data/latest.json
//
// Reads the most recent buoy reading from the shared JSON file the
// Gleam ingest writes, populates the Now card, and runs an animated
// SVG sine wave whose amplitude tracks Hs and wavelength tracks Tp.
//
// Degrades gracefully: missing fields render "—"; missing data file
// shows a status hint; missing wave/period switches the animation into a
// slow amplitude breath ("the buoy is silent but we're listening").

const KNOTS_PER_MS = 1.94384;
const FEET_PER_M = 3.28084;

const els = {
  wave:      document.getElementById('m-wave'),
  period:    document.getElementById('m-period'),
  wind:      document.getElementById('m-wind'),
  tide:      document.getElementById('m-tide'),
  source:    document.getElementById('now-source'),
  updated:   document.getElementById('now-updated'),
  // Scaffolding: single-line render targets wave-mean (turquoise) so the
  // breath fallback color is preserved. Task 12 will replace this with
  // explicit per-layer els (swell/mean/chop).
  path:      document.getElementById('wave-mean'),
  card:      document.querySelector('.now'),
  stalePill: document.getElementById('stale-pill'),
};

const STALE_THRESHOLD_MS = 2 * 60 * 60 * 1000;  // 2 hours

// Wave animation state. Updated by render() when fresh data lands.
// `period_s` switches the motion mode: number → step-tick at ocean speed,
// null → smooth amplitude breath (the "buoy is silent but we're listening" state).
const wave = {
  amplitude: 4,    // viewBox px
  wavelength: 200, // viewBox px
  period_s: null,  // real ocean period; drives step-tick rate
  phase: 0,
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

  els.tide.textContent = formatTide(tide);

  // Spot name, not sensor name. Hardcoded until spots/<spot>.json lands.
  els.source.textContent = 'Pass-a-Grille';
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

  // === wave-animation mapping ===
  //
  // Map ocean physics → SVG viewBox space (W=800, H=100, so 1 px == 1 unit).
  //   amplitude  = clamp(Hs_m * 20, 5, 40)    px
  //     0.25m → 5  (floor: even tiny chop renders visibly)
  //     1.0m  → 20 (mid)
  //     2.0m+ → 40 (cap: head-high days don't blow past viewBox)
  //   wavelength = clamp(Tp_s * 30, 60, 400)  px
  //     3s    → 90  (short period, choppy look)
  //     8s    → 240 (rolling swell)
  //     14s+  → 400 (cap: roughly one wave per SVG width)
  //
  // The 20× / 30× multipliers were chosen so a "real but unspectacular Gulf
  // day" (1m / 8s) lands mid-frame. Numbers are taste, not science — adjust
  // them, don't add more state. When picker returns null, fall through to
  // breath mode (slow amplitude oscillation, no real Tp); see Motion section.
  if (picked.heightM != null && picked.periodS != null) {
    wave.amplitude  = clamp(picked.heightM * 20, 5, 40);
    wave.wavelength = clamp(picked.periodS * 30, 60, 400);
    wave.period_s   = picked.periodS;
  } else {
    wave.wavelength = 200;
    wave.period_s   = null;
    // amplitude is owned by the breath loop in this mode; don't fight it
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

function formatTimestamp(iso) {
  const d = new Date(iso);
  if (isNaN(d.getTime())) return iso;
  const hh = String(d.getUTCHours()).padStart(2, '0');
  const mm = String(d.getUTCMinutes()).padStart(2, '0');
  return `${hh}:${mm} UTC · ${d.getUTCMonth() + 1}/${d.getUTCDate()}`;
}

function formatTimeOnly(iso) {
  const d = new Date(iso);
  if (isNaN(d.getTime())) return iso;
  const hh = String(d.getUTCHours()).padStart(2, '0');
  const mm = String(d.getUTCMinutes()).padStart(2, '0');
  return `${hh}:${mm} UTC`;
}

function formatTide(t) {
  if (!t) return '—';
  const ht = t.height_ft != null ? `${t.height_ft.toFixed(1)} ft` : '—';
  const trend = t.trend ?? '';
  const ne = t.next_event;
  const evt = ne ? `${ne.kind} at ${formatTimeOnly(ne.at_utc)}` : '';
  return [ht, trend, evt].filter(Boolean).join(' · ');
}

function clamp(v, lo, hi) {
  return Math.max(lo, Math.min(hi, v));
}

// === Motion ===
//
// Two modes, picked by render() via wave.period_s:
//   step-tick — discrete 1Hz phase advance, one full wavelength per Tp seconds.
//               The wave noticeably "ticks" forward at the real ocean rhythm.
//   breath    — smooth amplitude oscillation, no phase drift. Used when the
//               buoy is silent on wave fields. Reads as quietly alive.
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
    drawWave();
    return;
  }
  if (wave.period_s != null) {
    drawWave();
    stepIntervalId = setInterval(() => {
      wave.phase += (2 * Math.PI) / (wave.period_s * STEP_HZ);
      drawWave();
    }, 1000 / STEP_HZ);
  } else {
    const origin = performance.now();
    let lastFrame = origin;
    const loop = (now) => {
      const dt = (now - lastFrame) / 1000;
      lastFrame = now;
      const t = (now - origin) / 1000;
      const mid = (BREATH_AMP_MIN + BREATH_AMP_MAX) / 2;
      const swing = (BREATH_AMP_MAX - BREATH_AMP_MIN) / 2;
      wave.amplitude = mid + swing * Math.sin((2 * Math.PI * t) / BREATH_PERIOD_S);
      wave.phase += (2 * Math.PI * dt) / BREATH_DRIFT_PERIOD_S;
      drawWave();
      breathRafId = requestAnimationFrame(loop);
    };
    breathRafId = requestAnimationFrame(loop);
  }
}

function stopMotion() {
  if (stepIntervalId) { clearInterval(stepIntervalId); stepIntervalId = null; }
  if (breathRafId)    { cancelAnimationFrame(breathRafId); breathRafId = null; }
}

function drawWave() {
  const W = 800, H = 100, cy = H / 2;
  const samples = 200;
  let d = `M0,${cy}`;
  for (let i = 1; i <= samples; i++) {
    const x = (i / samples) * W;
    const y = cy - wave.amplitude * Math.sin(
      (x / wave.wavelength) * Math.PI * 2 - wave.phase
    );
    d += ` L${x.toFixed(1)},${y.toFixed(2)}`;
  }
  els.path.setAttribute('d', d);
}

load();
startMotion();

// Re-evaluate motion mode if the OS reduced-motion preference toggles live.
window.matchMedia('(prefers-reduced-motion: reduce)')
  .addEventListener('change', startMotion);
