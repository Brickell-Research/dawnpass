//// Open-Meteo Forecast source — hourly coastal wind.
////
//// Pulls 10m wind speed + direction at a given lat/lon from
//// api.open-meteo.com. Free, no key. Same response shape as the marine
//// source but on the regular forecast endpoint (not the marine one).
////
//// Used by the scoring engine: NDBC 42036 wind is offshore (~30nm out)
//// and structurally 2-3× shore wind. The scoring engine needs *coastal*
//// wind for the offshore/onshore quality calculation. This source feeds
//// the wind axis for both "now" and each forecast hour.

import gleam/dynamic/decode
import gleam/float
import gleam/http/request
import gleam/httpc
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type WindForecast {
  WindForecast(
    latitude: Float,
    longitude: Float,
    observed_at_utc: String,
    wind_speed_ms: Option(Float),
    wind_direction_deg: Option(Int),
    forecast: List(WindForecastHour),
  )
}

pub type WindForecastHour {
  WindForecastHour(
    at_utc: String,
    wind_speed_ms: Option(Float),
    wind_direction_deg: Option(Int),
  )
}

pub type ForecastError {
  HttpError(httpc.HttpError)
  InvalidUrl(String)
  JsonDecodeError(json.DecodeError)
  ParseError(String)
}

const api_base = "https://api.open-meteo.com/v1/forecast"

const user_agent = "dawnpass/0.1 (https://dawnpass.brickellresearch.org)"

pub fn fetch_wind(
  latitude latitude: Float,
  longitude longitude: Float,
) -> Result(WindForecast, ForecastError) {
  let url =
    api_base
    <> "?latitude="
    <> float.to_string(latitude)
    <> "&longitude="
    <> float.to_string(longitude)
    <> "&current=wind_speed_10m,wind_direction_10m"
    <> "&hourly=wind_speed_10m,wind_direction_10m"
    <> "&wind_speed_unit=ms"
    <> "&forecast_days=3"
    <> "&timezone=GMT"

  use base_req <- result.try(
    request.to(url) |> result.replace_error(InvalidUrl(url)),
  )
  let req = request.set_header(base_req, "user-agent", user_agent)
  use resp <- result.try(httpc.send(req) |> result.map_error(HttpError))

  parse_forecast(resp.body)
}

pub fn parse_forecast(body: String) -> Result(WindForecast, ForecastError) {
  let current_decoder = {
    use time <- decode.field("time", decode.string)
    use ws <- decode.field("wind_speed_10m", decode.optional(decode.float))
    use wd <- decode.field("wind_direction_10m", decode.optional(decode.int))
    decode.success(#(time, ws, wd))
  }
  let hourly_decoder = {
    use times <- decode.field("time", decode.list(decode.string))
    use speeds <- decode.field(
      "wind_speed_10m",
      decode.list(decode.optional(decode.float)),
    )
    use dirs <- decode.field(
      "wind_direction_10m",
      decode.list(decode.optional(decode.int)),
    )
    decode.success(#(times, speeds, dirs))
  }
  let decoder = {
    use latitude <- decode.field("latitude", decode.float)
    use longitude <- decode.field("longitude", decode.float)
    use current <- decode.field("current", current_decoder)
    use hourly <- decode.field("hourly", hourly_decoder)
    let #(time, ws, wd) = current
    let #(times, speeds, dirs) = hourly
    decode.success(WindForecast(
      latitude:,
      longitude:,
      observed_at_utc: normalize_timestamp(time),
      wind_speed_ms: ws,
      wind_direction_deg: wd,
      forecast: zip3_hours(times, speeds, dirs),
    ))
  }

  case json.parse(body, decoder) {
    Ok(reading) -> Ok(reading)
    Error(e) -> Error(JsonDecodeError(e))
  }
}

fn zip3_hours(
  ts: List(String),
  ss: List(Option(Float)),
  ds: List(Option(Int)),
) -> List(WindForecastHour) {
  case ts, ss, ds {
    [t, ..ts2], [s, ..ss2], [d, ..ds2] -> [
      WindForecastHour(
        at_utc: normalize_timestamp(t),
        wind_speed_ms: s,
        wind_direction_deg: d,
      ),
      ..zip3_hours(ts2, ss2, ds2)
    ]
    _, _, _ -> []
  }
}

pub fn normalize_timestamp(s: String) -> String {
  case string.ends_with(s, "Z") {
    True -> s
    False ->
      case string.length(s) {
        16 -> s <> ":00Z"
        19 -> s <> "Z"
        _ -> s
      }
  }
}

pub fn encode(w: WindForecast) -> json.Json {
  json.object([
    #("latitude", json.float(w.latitude)),
    #("longitude", json.float(w.longitude)),
    #("observed_at_utc", json.string(w.observed_at_utc)),
    #("wind_speed_ms", encode_optional(w.wind_speed_ms, json.float)),
    #("wind_direction_deg", encode_optional(w.wind_direction_deg, json.int)),
    #("forecast", json.array(w.forecast, of: encode_forecast_hour)),
  ])
}

fn encode_forecast_hour(h: WindForecastHour) -> json.Json {
  json.object([
    #("at_utc", json.string(h.at_utc)),
    #("wind_speed_ms", encode_optional(h.wind_speed_ms, json.float)),
    #("wind_direction_deg", encode_optional(h.wind_direction_deg, json.int)),
  ])
}

fn encode_optional(o: Option(a), encode: fn(a) -> json.Json) -> json.Json {
  case o {
    None -> json.null()
    Some(v) -> encode(v)
  }
}
