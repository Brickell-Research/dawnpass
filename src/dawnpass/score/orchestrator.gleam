//// Score orchestration — turn raw source readings into a scored JSON block.
////
//// Builds Conditions for "now" + each forecast hour, runs the pure
//// scoring engine on each, detects windows, encodes everything as the
//// "score" object the static site reads. Lives between sources and
//// ingest.gleam — neither knows about scoring concerns.

import dawnpass/score/conditions.{
  type Conditions, type TidePhase, Conditions, Falling, HighSlack, LowSlack,
  Rising,
}
import dawnpass/score/score.{type Score}
import dawnpass/score/spot_config.{type SpotConfig}
import dawnpass/score/window.{type ScoredHour, type Window, ScoredHour}
import dawnpass/sources/ndbc.{type BuoyReading}
import dawnpass/sources/noaa_tides.{type TideReading} as nt
import dawnpass/sources/open_meteo_forecast.{
  type WindForecast, type WindForecastHour,
}
import dawnpass/sources/open_meteo_marine.{
  type MarineForecastHour, type MarineReading,
}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

const knots_per_ms = 1.94384

/// Build the "score" JSON value from raw sources + a spot config.
pub fn build_block(
  buoy: Option(BuoyReading),
  tide: Option(TideReading),
  marine: Option(MarineReading),
  wind: Option(WindForecast),
  spot: SpotConfig,
) -> json.Json {
  let now_iso = pick_now_iso(buoy, tide, marine)
  let now_conditions = build_now_conditions(now_iso, buoy, tide, marine, wind)
  let now_score = score.score(now_conditions, spot)

  let scored_hours = build_scored_hours(marine, wind, spot)
  let windows = window.detect(scored_hours, spot.windows, now_iso)
  let best_today = window.best_today(windows)
  let best_overall = window.best_overall(windows)

  encode_block(now_score, scored_hours, windows, best_today, best_overall)
}

// === Conditions builders ===

fn build_now_conditions(
  now_iso: String,
  buoy: Option(BuoyReading),
  tide: Option(TideReading),
  marine: Option(MarineReading),
  wind: Option(WindForecast),
) -> Conditions {
  Conditions(
    at_utc: now_iso,
    hs_m: pick_hs(buoy, marine),
    tp_s: pick_tp(buoy, marine),
    swell_dir_deg: pick_swell_dir(buoy, marine),
    wind_kt: pick_wind_kt(wind, buoy),
    wind_dir_deg: pick_wind_dir(wind, buoy),
    tide_ft: option.map(tide, fn(t) { t.height_ft }),
    tide_phase: derive_tide_phase(tide),
  )
}

fn build_scored_hours(
  marine: Option(MarineReading),
  wind: Option(WindForecast),
  spot: SpotConfig,
) -> List(ScoredHour) {
  case marine, wind {
    Some(m), Some(w) -> {
      list.map(m.forecast, fn(mh) {
        let wh = find_wind_hour(w.forecast, mh.at_utc)
        let cs = forecast_conditions(mh, wh)
        ScoredHour(at_utc: mh.at_utc, score: score.score(cs, spot))
      })
    }
    Some(m), None ->
      list.map(m.forecast, fn(mh) {
        let cs = forecast_conditions(mh, None)
        ScoredHour(at_utc: mh.at_utc, score: score.score(cs, spot))
      })
    _, _ -> []
  }
}

fn forecast_conditions(
  mh: MarineForecastHour,
  wh: Option(WindForecastHour),
) -> Conditions {
  let wind_kt =
    option.then(wh, fn(w) {
      option.map(w.wind_speed_ms, fn(ms) { ms *. knots_per_ms })
    })
  let wind_dir = option.then(wh, fn(w) { w.wind_direction_deg })
  Conditions(
    at_utc: mh.at_utc,
    hs_m: mh.wave_height_m,
    tp_s: mh.wave_period_s,
    swell_dir_deg: mh.wave_direction_deg,
    wind_kt:,
    wind_dir_deg: wind_dir,
    tide_ft: None,
    tide_phase: None,
  )
}

fn find_wind_hour(
  hours: List(WindForecastHour),
  at_utc: String,
) -> Option(WindForecastHour) {
  case list.find(hours, fn(h) { h.at_utc == at_utc }) {
    Ok(h) -> Some(h)
    Error(_) -> None
  }
}

// === Source-precedence pickers ===

fn pick_hs(
  buoy: Option(BuoyReading),
  marine: Option(MarineReading),
) -> Option(Float) {
  case option.then(buoy, fn(b) { b.wave_height_m }) {
    Some(v) -> Some(v)
    None -> option.then(marine, fn(m) { m.wave_height_m })
  }
}

fn pick_tp(
  buoy: Option(BuoyReading),
  marine: Option(MarineReading),
) -> Option(Float) {
  case option.then(buoy, fn(b) { b.dominant_period_s }) {
    Some(v) -> Some(v)
    None -> option.then(marine, fn(m) { m.wave_period_s })
  }
}

fn pick_swell_dir(
  buoy: Option(BuoyReading),
  marine: Option(MarineReading),
) -> Option(Int) {
  case option.then(buoy, fn(b) { b.mean_wave_direction_deg }) {
    Some(v) -> Some(v)
    None -> option.then(marine, fn(m) { m.wave_direction_deg })
  }
}

fn pick_wind_kt(
  wind: Option(WindForecast),
  buoy: Option(BuoyReading),
) -> Option(Float) {
  // Prefer coastal forecast wind (Open-Meteo) — matches what surfers feel
  // at the beach. Buoy fallback is offshore and structurally 2-3× higher.
  case option.then(wind, fn(w) { w.wind_speed_ms }) {
    Some(ms) -> Some(ms *. knots_per_ms)
    None ->
      option.then(buoy, fn(b) {
        option.map(b.wind_speed_ms, fn(ms) { ms *. knots_per_ms })
      })
  }
}

fn pick_wind_dir(
  wind: Option(WindForecast),
  buoy: Option(BuoyReading),
) -> Option(Int) {
  case option.then(wind, fn(w) { w.wind_direction_deg }) {
    Some(v) -> Some(v)
    None -> option.then(buoy, fn(b) { b.wind_direction_deg })
  }
}

// === Tide phase derivation ===

fn derive_tide_phase(tide: Option(TideReading)) -> Option(TidePhase) {
  case tide {
    None -> None
    Some(t) -> {
      let near_event =
        minutes_until(t.observed_at_utc, t.next_event.at_utc) <= 30
      case near_event, t.next_event.kind {
        True, nt.High -> Some(HighSlack)
        True, nt.Low -> Some(LowSlack)
        False, _ ->
          case t.trend {
            nt.Rising -> Some(Rising)
            nt.Falling -> Some(Falling)
            nt.Slack ->
              case t.next_event.kind {
                nt.High -> Some(HighSlack)
                nt.Low -> Some(LowSlack)
              }
          }
      }
    }
  }
}

// === "Now" timestamp picker ===

fn pick_now_iso(
  buoy: Option(BuoyReading),
  tide: Option(TideReading),
  marine: Option(MarineReading),
) -> String {
  // Use the most recent observation as our "now" reference. Falls back
  // through buoy → tide → marine. Empty string if all sources failed
  // (the score block will be largely empty).
  case buoy {
    Some(b) -> b.observed_at_utc
    None ->
      case tide {
        Some(t) -> t.observed_at_utc
        None ->
          case marine {
            Some(m) -> m.observed_at_utc
            None -> ""
          }
      }
  }
}

// === Crude minutes-between helper (mirrors noaa_tides) ===

fn minutes_until(now_iso: String, then_iso: String) -> Int {
  case to_minutes(now_iso), to_minutes(then_iso) {
    Ok(a), Ok(b) ->
      case b - a {
        d if d < 0 -> 0
        d -> d
      }
    _, _ -> 0
  }
}

fn to_minutes(iso: String) -> Result(Int, Nil) {
  case string.length(iso) >= 16 {
    False -> Error(Nil)
    True -> {
      use yyyy <- result_try(int.parse(string.slice(iso, 0, 4)))
      use mo <- result_try(int.parse(string.slice(iso, 5, 2)))
      use dd <- result_try(int.parse(string.slice(iso, 8, 2)))
      use hh <- result_try(int.parse(string.slice(iso, 11, 2)))
      use mm <- result_try(int.parse(string.slice(iso, 14, 2)))
      Ok({ { { { yyyy * 12 + mo } * 31 + dd } * 24 + hh } * 60 + mm })
    }
  }
}

fn result_try(r: Result(a, e), f: fn(a) -> Result(b, e)) -> Result(b, e) {
  case r {
    Ok(v) -> f(v)
    Error(e) -> Error(e)
  }
}

// === JSON encoding ===

fn encode_block(
  now_score: Score,
  scored_hours: List(ScoredHour),
  windows: List(Window),
  best_today: Option(Window),
  best_overall: Option(Window),
) -> json.Json {
  json.object([
    #("now", encode_score(now_score)),
    #("forecast", json.array(scored_hours, of: encode_scored_hour)),
    #("windows", json.array(windows, of: encode_window)),
    #("best_today", encode_optional_window(best_today)),
    #("best_overall", encode_optional_window(best_overall)),
  ])
}

fn encode_score(s: Score) -> json.Json {
  json.object([
    #("overall", json.float(s.overall)),
    #("rideable", json.bool(s.rideable)),
    #("verdict", json.string(s.verdict)),
    #(
      "sub_scores",
      json.array(s.sub_scores, of: fn(pair) {
        let #(name, v) = pair
        json.object([#("name", json.string(name)), #("value", json.float(v))])
      }),
    ),
    #("vetoes", json.array(s.vetoes, of: json.string)),
  ])
}

fn encode_scored_hour(h: ScoredHour) -> json.Json {
  json.object([
    #("at_utc", json.string(h.at_utc)),
    #("score", encode_score(h.score)),
  ])
}

fn encode_window(w: Window) -> json.Json {
  json.object([
    #("starts_at", json.string(w.starts_at)),
    #("ends_at", json.string(w.ends_at)),
    #("length_hours", json.int(w.length_hours)),
    #("peak_score", json.float(w.peak_score)),
    #("peak_at", json.string(w.peak_at)),
    #("mean_score", json.float(w.mean_score)),
    #("composite", json.float(w.composite)),
    #("horizon_hours_out", json.int(w.horizon_hours_out)),
    #("confidence", json.string(w.confidence)),
  ])
}

fn encode_optional_window(w: Option(Window)) -> json.Json {
  case w {
    None -> json.null()
    Some(window) -> encode_window(window)
  }
}
