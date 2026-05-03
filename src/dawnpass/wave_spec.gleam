//// Wave-visualisation math layer.
////
//// The single source of truth for the formulas that map an ocean reading
//// (buoy + marine) onto the three SVG sine layers the renderer animates.
////
//// Lives in Gleam (not JS) so the math is testable, frozen behind types,
//// and shared with future server-rendered SVG. The renderer (public/wave.js)
//// reads the encoded WaveLayers from latest.json and copies values straight
//// onto its layer state — no client-side recomputation.
////
//// Source picker: buoy when both Hs and Tp are present, else marine when
//// both are present, else Silent. All-or-nothing per source — never mix Hs
//// from one with Tp from another. Direction picker is independent and falls
//// through to marine when buoy direction is null. Wind (and therefore chop)
//// always comes from the buoy regardless of which source feeds Hs/Tp.
////
//// Numbers (multipliers, clamps) are taste, not science — adjust them in
//// the named constants below.

import dawnpass/sources/ndbc
import dawnpass/sources/open_meteo_marine
import gleam/json
import gleam/option.{type Option, None, Some}

// === Public types ===

pub type WaveSource {
  Buoy(station: String)
  Marine(spot: String)
  Silent
}

pub type Layer {
  Layer(amp: Float, lambda: Float, period_s: Option(Float))
}

pub type WaveLayers {
  WaveLayers(
    source: WaveSource,
    height_m: Option(Float),
    period_s: Option(Float),
    direction_deg: Option(Int),
    swell: Layer,
    mean: Layer,
    chop: Layer,
  )
}

// === Tunable constants ===
//
// Map ocean physics → SVG viewBox space (W=800, H=100). One viewBox unit
// is one pixel at the rendered SVG aspect, so amp values are in px.
//
//   swell amp = clamp(Hs_m * swell_amp_mult, swell_amp_min, swell_amp_max)
//   mean  amp = clamp(Hs_m * mean_amp_mult,  mean_amp_min,  mean_amp_max)
//   chop  amp = clamp(ws_ms * chop_amp_mult, 0,             chop_amp_max)
//                when ws_ms > chop_wind_min_ms, else 0
//
//   swell λ   = clamp(Tp_s * period_mult, lambda_min, lambda_max)
//   mean  λ   = clamp(Tm_s * period_mult, lambda_min, lambda_max)
//   chop  λ   = chop_lambda  (fixed; NDBC ships no chop period)
//   chop  T   = chop_period_s (fixed)

const swell_amp_mult: Float = 30.0

const swell_amp_min: Float = 6.0

const swell_amp_max: Float = 45.0

const mean_amp_mult: Float = 18.0

const mean_amp_min: Float = 4.0

const mean_amp_max: Float = 30.0

const period_mult: Float = 30.0

const lambda_min: Float = 60.0

const lambda_max: Float = 400.0

const chop_amp_mult: Float = 0.75

const chop_amp_max: Float = 6.0

const chop_lambda: Float = 30.0

const chop_period_s: Float = 2.0

const chop_wind_min_ms: Float = 3.0

// Silent-state mean wavelength — kept stable so the breath loop has a
// reasonable visual base when wave fields are null.
const silent_mean_lambda: Float = 200.0

// === Computation ===

pub fn compute_layers(
  buoy: Option(ndbc.BuoyReading),
  marine: Option(open_meteo_marine.MarineReading),
) -> WaveLayers {
  let direction = pick_direction(buoy, marine)
  let chop = chop_layer(buoy)

  case pick_source(buoy, marine) {
    PickedBuoy(b, hs, tp) -> {
      let tm = case b.avg_period_s {
        Some(v) -> v
        None -> tp
      }
      WaveLayers(
        source: Buoy(b.station),
        height_m: Some(hs),
        period_s: Some(tp),
        direction_deg: direction,
        swell: stroke_layer(
          hs,
          tp,
          swell_amp_mult,
          swell_amp_min,
          swell_amp_max,
        ),
        mean: stroke_layer(hs, tm, mean_amp_mult, mean_amp_min, mean_amp_max),
        chop:,
      )
    }
    PickedMarine(spot, hs, tp) ->
      WaveLayers(
        source: Marine(spot),
        height_m: Some(hs),
        period_s: Some(tp),
        direction_deg: direction,
        swell: stroke_layer(
          hs,
          tp,
          swell_amp_mult,
          swell_amp_min,
          swell_amp_max,
        ),
        // No Tm available — mean collapses onto swell. Renderer skips drawing
        // it (same period as swell → identical shape, pure visual noise).
        mean: stroke_layer(hs, tp, mean_amp_mult, mean_amp_min, mean_amp_max),
        chop:,
      )
    PickedSilent ->
      WaveLayers(
        source: Silent,
        height_m: None,
        period_s: None,
        direction_deg: direction,
        swell: Layer(amp: 0.0, lambda: silent_mean_lambda, period_s: None),
        mean: Layer(amp: 0.0, lambda: silent_mean_lambda, period_s: None),
        chop: Layer(
          amp: 0.0,
          lambda: chop_lambda,
          period_s: Some(chop_period_s),
        ),
      )
  }
}

fn stroke_layer(
  hs: Float,
  period_s: Float,
  amp_mult: Float,
  amp_min: Float,
  amp_max: Float,
) -> Layer {
  Layer(
    amp: clamp(hs *. amp_mult, amp_min, amp_max),
    lambda: clamp(period_s *. period_mult, lambda_min, lambda_max),
    period_s: Some(period_s),
  )
}

fn chop_layer(buoy: Option(ndbc.BuoyReading)) -> Layer {
  let amp = case buoy {
    Some(b) ->
      case b.wind_speed_ms {
        Some(ws) ->
          case ws >. chop_wind_min_ms {
            True -> clamp(ws *. chop_amp_mult, 0.0, chop_amp_max)
            False -> 0.0
          }
        None -> 0.0
      }
    None -> 0.0
  }
  Layer(amp:, lambda: chop_lambda, period_s: Some(chop_period_s))
}

// === Source picking ===

type Picked {
  PickedBuoy(reading: ndbc.BuoyReading, height_m: Float, period_s: Float)
  PickedMarine(spot: String, height_m: Float, period_s: Float)
  PickedSilent
}

fn pick_source(
  buoy: Option(ndbc.BuoyReading),
  marine: Option(open_meteo_marine.MarineReading),
) -> Picked {
  case buoy {
    Some(b) ->
      case b.wave_height_m, b.dominant_period_s {
        Some(h), Some(t) -> PickedBuoy(b, h, t)
        _, _ -> pick_marine(marine)
      }
    None -> pick_marine(marine)
  }
}

fn pick_marine(marine: Option(open_meteo_marine.MarineReading)) -> Picked {
  case marine {
    Some(m) ->
      case m.wave_height_m, m.wave_period_s {
        // Spot label hardcoded until spot configs land — matches the JS
        // pickWaveSource's "marine · pag" string.
        Some(h), Some(t) -> PickedMarine("pag", h, t)
        _, _ -> PickedSilent
      }
    None -> PickedSilent
  }
}

fn pick_direction(
  buoy: Option(ndbc.BuoyReading),
  marine: Option(open_meteo_marine.MarineReading),
) -> Option(Int) {
  let buoy_dir = case buoy {
    Some(b) -> b.mean_wave_direction_deg
    None -> None
  }
  case buoy_dir {
    Some(_) -> buoy_dir
    None ->
      case marine {
        Some(m) -> m.wave_direction_deg
        None -> None
      }
  }
}

// === Helpers ===

pub fn clamp(v: Float, lo: Float, hi: Float) -> Float {
  case v <. lo, v >. hi {
    True, _ -> lo
    _, True -> hi
    _, _ -> v
  }
}

// === JSON encoding (used by task 27 / dawnpass.gleam) ===

pub fn encode(w: WaveLayers) -> json.Json {
  json.object([
    #("source", json.string(encode_source(w.source))),
    #("height_m", encode_optional(w.height_m, json.float)),
    #("period_s", encode_optional(w.period_s, json.float)),
    #("direction_deg", encode_optional(w.direction_deg, json.int)),
    #("swell", encode_layer(w.swell)),
    #("mean", encode_layer(w.mean)),
    #("chop", encode_layer(w.chop)),
  ])
}

fn encode_source(s: WaveSource) -> String {
  case s {
    Buoy(station) -> "buoy:" <> station
    Marine(spot) -> "marine:" <> spot
    Silent -> "silent"
  }
}

fn encode_layer(l: Layer) -> json.Json {
  json.object([
    #("amp", json.float(l.amp)),
    #("lambda", json.float(l.lambda)),
    #("period_s", encode_optional(l.period_s, json.float)),
  ])
}

fn encode_optional(o: Option(a), encode: fn(a) -> json.Json) -> json.Json {
  case o {
    None -> json.null()
    Some(v) -> encode(v)
  }
}
