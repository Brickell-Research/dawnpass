//// Open-Meteo Marine source.
////
//// Pulls *forecast-model* current wave fields (Hs, Tp, swell direction)
//// at a given lat/lon from marine-api.open-meteo.com. Free, no key.
////
//// Acts as a fallback for sparse buoy fields: NDBC 42036 routinely
//// reports wave_height_m as null in calm Gulf conditions, while the
//// model still gives a reasonable estimate at the actual coastal
//// coordinate.
////
//// Pure parsing helpers are pub so a future test module can hit them
//// with fixture JSON without a live network call.

import gleam/dynamic/decode
import gleam/float
import gleam/http/request
import gleam/httpc
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type MarineReading {
  MarineReading(
    latitude: Float,
    longitude: Float,
    observed_at_utc: String,
    wave_height_m: Option(Float),
    wave_period_s: Option(Float),
    wave_direction_deg: Option(Int),
    /// Sea-surface temperature in °C from the model. Used as the renderer's
    /// fallback when the NDBC buoy (the primary water-temp source) is silent.
    sst_c: Option(Float),
    forecast: List(MarineForecastHour),
  )
}

/// One hour of model forecast — the parallel hourly arrays from
/// open-meteo-marine zipped into per-hour records.
pub type MarineForecastHour {
  MarineForecastHour(
    at_utc: String,
    wave_height_m: Option(Float),
    wave_period_s: Option(Float),
    wave_direction_deg: Option(Int),
  )
}

pub type MarineError {
  HttpError(httpc.HttpError)
  InvalidUrl(String)
  JsonDecodeError(json.DecodeError)
  ParseError(String)
}

const api_base = "https://marine-api.open-meteo.com/v1/marine"

const user_agent = "dawnpass/0.1 (https://dawnpass.brickellresearch.org)"

// === HTTP fetch ===

/// Fetch the current wave conditions + a 5-day hourly forecast at the
/// given coordinate. One HTTP call returns both blocks. GFS-Wave skill
/// drops past day 3 — the renderer fades days 4-5 to surface that.
pub fn fetch_marine(
  latitude latitude: Float,
  longitude longitude: Float,
) -> Result(MarineReading, MarineError) {
  let url =
    api_base
    <> "?latitude="
    <> float.to_string(latitude)
    <> "&longitude="
    <> float.to_string(longitude)
    <> "&current=wave_height,wave_period,wave_direction,sea_surface_temperature"
    <> "&hourly=wave_height,wave_period,wave_direction"
    <> "&forecast_days=5"
    <> "&timezone=GMT"

  use base_req <- result.try(
    request.to(url)
    |> result.replace_error(InvalidUrl(url)),
  )
  let req = request.set_header(base_req, "user-agent", user_agent)
  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(HttpError),
  )

  parse_marine(resp.body)
}

// === pure parsing (testable) ===

/// Parse an Open-Meteo Marine response into a MarineReading.
pub fn parse_marine(body: String) -> Result(MarineReading, MarineError) {
  let current_decoder = {
    use time <- decode.field("time", decode.string)
    use wh <- decode.field("wave_height", decode.optional(decode.float))
    use wp <- decode.field("wave_period", decode.optional(decode.float))
    use wd <- decode.field("wave_direction", decode.optional(decode.int))
    use sst <- decode.field(
      "sea_surface_temperature",
      decode.optional(decode.float),
    )
    decode.success(#(time, wh, wp, wd, sst))
  }
  let hourly_decoder = {
    use times <- decode.field("time", decode.list(decode.string))
    use heights <- decode.field(
      "wave_height",
      decode.list(decode.optional(decode.float)),
    )
    use periods <- decode.field(
      "wave_period",
      decode.list(decode.optional(decode.float)),
    )
    use dirs <- decode.field(
      "wave_direction",
      decode.list(decode.optional(decode.int)),
    )
    decode.success(#(times, heights, periods, dirs))
  }
  let decoder = {
    use latitude <- decode.field("latitude", decode.float)
    use longitude <- decode.field("longitude", decode.float)
    use current <- decode.field("current", current_decoder)
    use hourly <- decode.field("hourly", hourly_decoder)
    let #(time, wh, wp, wd, sst) = current
    let #(times, heights, periods, dirs) = hourly
    decode.success(MarineReading(
      latitude:,
      longitude:,
      observed_at_utc: normalize_timestamp(time),
      wave_height_m: wh,
      wave_period_s: wp,
      wave_direction_deg: wd,
      sst_c: sst,
      forecast: zip4_hours(times, heights, periods, dirs),
    ))
  }

  case json.parse(body, decoder) {
    Ok(reading) -> Ok(reading)
    Error(e) -> Error(JsonDecodeError(e))
  }
}

/// Weave the four parallel hourly arrays into a list of MarineForecastHour.
/// Stops at the shortest input (defensive against API field-length mismatch).
fn zip4_hours(
  ts: List(String),
  hs: List(Option(Float)),
  ps: List(Option(Float)),
  ds: List(Option(Int)),
) -> List(MarineForecastHour) {
  case ts, hs, ps, ds {
    [t, ..ts2], [h, ..hs2], [p, ..ps2], [d, ..ds2] -> [
      MarineForecastHour(
        at_utc: normalize_timestamp(t),
        wave_height_m: h,
        wave_period_s: p,
        wave_direction_deg: d,
      ),
      ..zip4_hours(ts2, hs2, ps2, ds2)
    ]
    _, _, _, _ -> []
  }
}

/// "2026-05-03T18:00" → "2026-05-03T18:00:00Z". Idempotent for already-Z inputs.
pub fn normalize_timestamp(s: String) -> String {
  case string.ends_with(s, "Z") {
    True -> s
    False ->
      case string.length(s) {
        16 -> s <> ":00Z"
        // "YYYY-MM-DDTHH:MM"
        19 -> s <> "Z"
        // "YYYY-MM-DDTHH:MM:SS"
        _ -> s
      }
  }
}

// === JSON encoding ===

/// Serialise a marine reading. ingest.gleam wraps under "marine_<spot>".
pub fn encode(r: MarineReading) -> json.Json {
  json.object([
    #("latitude", json.float(r.latitude)),
    #("longitude", json.float(r.longitude)),
    #("observed_at_utc", json.string(r.observed_at_utc)),
    #("wave_height_m", encode_optional(r.wave_height_m, json.float)),
    #("wave_period_s", encode_optional(r.wave_period_s, json.float)),
    #("wave_direction_deg", encode_optional(r.wave_direction_deg, json.int)),
    #("sst_c", encode_optional(r.sst_c, json.float)),
    #("forecast", json.array(r.forecast, of: encode_forecast_hour)),
  ])
}

fn encode_forecast_hour(h: MarineForecastHour) -> json.Json {
  json.object([
    #("at_utc", json.string(h.at_utc)),
    #("wave_height_m", encode_optional(h.wave_height_m, json.float)),
    #("wave_period_s", encode_optional(h.wave_period_s, json.float)),
    #("wave_direction_deg", encode_optional(h.wave_direction_deg, json.int)),
  ])
}

fn encode_optional(o: Option(a), encode: fn(a) -> json.Json) -> json.Json {
  case o {
    None -> json.null()
    Some(v) -> encode(v)
  }
}
