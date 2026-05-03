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
  wave:    document.getElementById('m-wave'),
  period:  document.getElementById('m-period'),
  wind:    document.getElementById('m-wind'),
  source:  document.getElementById('now-source'),
  updated: document.getElementById('now-updated'),
  path:    document.getElementById('wave-path'),
};

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
  // v0 JSON shape: { "buoy_<station>": { ...BuoyReading } }.
  // Future shapes (tide, marine) will add sibling keys.
  const buoyKey = Object.keys(data).find(k => k.startsWith('buoy_'));
  const r = buoyKey ? data[buoyKey] : null;
  if (!r) return setStatus('no buoy reading');

  els.wave.textContent = r.wave_height_m != null
    ? `${(r.wave_height_m * FEET_PER_M).toFixed(1)} ft`
    : '—';

  els.period.textContent = r.dominant_period_s != null
    ? `${r.dominant_period_s.toFixed(0)} s`
    : '—';

  els.wind.textContent = formatWind(r.wind_speed_ms, r.wind_direction_deg);

  els.source.textContent = `buoy ${r.station}`;
  els.updated.textContent = r.observed_at_utc
    ? `updated ${formatTimestamp(r.observed_at_utc)}`
    : 'no timestamp';

  if (r.wave_height_m != null && r.dominant_period_s != null) {
    wave.amplitude  = clamp(r.wave_height_m * 20, 5, 40);
    wave.wavelength = clamp(r.dominant_period_s * 30, 60, 400);
    wave.period_s   = r.dominant_period_s;
  } else {
    wave.wavelength = 200;
    wave.period_s   = null;
    // amplitude is owned by the breath loop in this mode; don't fight it
  }

  startMotion();
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

let stepIntervalId = null;
let breathRafId = null;

function startMotion() {
  stopMotion();
  if (wave.period_s != null) {
    drawWave();
    stepIntervalId = setInterval(() => {
      wave.phase += (2 * Math.PI) / (wave.period_s * STEP_HZ);
      drawWave();
    }, 1000 / STEP_HZ);
  } else {
    const origin = performance.now();
    const loop = (now) => {
      const t = (now - origin) / 1000;
      const mid = (BREATH_AMP_MIN + BREATH_AMP_MAX) / 2;
      const swing = (BREATH_AMP_MAX - BREATH_AMP_MIN) / 2;
      wave.amplitude = mid + swing * Math.sin((2 * Math.PI * t) / BREATH_PERIOD_S);
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
