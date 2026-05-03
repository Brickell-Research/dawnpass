//// NDBC realtime2 buoy source.
////
//// HTTP fetch + parse for NDBC's realtime2 plain-text feed at
//// https://www.ndbc.noaa.gov/data/realtime2/<station>.txt
////
//// Pure parsing helpers (parse_realtime2_body, parse_realtime2_row,
//// iso_timestamp, parse_optional_*) are public so a future
//// sources/ndbc_test.gleam can exercise them with fixture data and
//// without spinning up a real HTTP request.

import gleam/float
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type BuoyReading {
  BuoyReading(
    station: String,
    observed_at_utc: String,
    wave_height_m: Option(Float),
    dominant_period_s: Option(Float),
    avg_period_s: Option(Float),
    mean_wave_direction_deg: Option(Int),
    wind_direction_deg: Option(Int),
    wind_speed_ms: Option(Float),
  )
}

pub type NdbcError {
  HttpError(httpc.HttpError)
  InvalidUrl(String)
  ParseError(String)
}

const realtime2_base = "https://www.ndbc.noaa.gov/data/realtime2/"

const user_agent = "dawnpass/0.1 (https://dawnpass.brickellresearch.org)"

// === HTTP fetch ===

/// Fetch the most recent reading from an NDBC realtime2 buoy feed.
pub fn fetch_buoy(station: String) -> Result(BuoyReading, NdbcError) {
  let url = realtime2_base <> station <> ".txt"

  use base_req <- result.try(
    request.to(url)
    |> result.replace_error(InvalidUrl(url)),
  )

  let req = request.set_header(base_req, "user-agent", user_agent)

  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(HttpError),
  )

  parse_realtime2_body(station, resp.body)
}

// === pure parsing (testable) ===

// NDBC realtime2 column layout (whitespace-separated, "MM" = missing):
//   0  YY    year (4-digit)         6  WSPD  wind speed, m/s
//   1  MM    month                  7  GST   gust, m/s              (ignored)
//   2  DD    day                    8  WVHT  significant wave height, m
//   3  hh    hour UTC               9  DPD   dominant wave period, s
//   4  mm    minute UTC            10  APD   average wave period, s
//   5  WDIR  wind direction, degT  11  MWD   mean wave direction, degT
// Remaining columns: PRES, ATMP, WTMP, DEWP, VIS, PTDY, TIDE.

/// Strip header (#-prefixed) and blank lines from an NDBC realtime2 body
/// and parse the most recent data row.
pub fn parse_realtime2_body(
  station: String,
  body: String,
) -> Result(BuoyReading, NdbcError) {
  let data_rows =
    body
    |> string.split("\n")
    |> list.filter(fn(l) { !string.starts_with(l, "#") && string.trim(l) != "" })

  case data_rows {
    [latest, ..] -> parse_realtime2_row(station, latest)
    [] -> Error(ParseError("no data rows for " <> station))
  }
}

/// Parse a single whitespace-separated NDBC realtime2 row.
pub fn parse_realtime2_row(
  station: String,
  row: String,
) -> Result(BuoyReading, NdbcError) {
  let cols =
    row
    |> string.split(" ")
    |> list.filter(fn(c) { c != "" })

  case cols {
    [yy, mm, dd, hh, mn, wdir, wspd, _gst, wvht, dpd, apd, mwd, ..] ->
      Ok(BuoyReading(
        station:,
        observed_at_utc: iso_timestamp(yy, mm, dd, hh, mn),
        wave_height_m: parse_optional_float(wvht),
        dominant_period_s: parse_optional_float(dpd),
        avg_period_s: parse_optional_float(apd),
        mean_wave_direction_deg: parse_optional_int(mwd),
        wind_direction_deg: parse_optional_int(wdir),
        wind_speed_ms: parse_optional_float(wspd),
      ))
    _ -> Error(ParseError("unexpected NDBC row: " <> row))
  }
}

pub fn iso_timestamp(
  yy: String,
  mm: String,
  dd: String,
  hh: String,
  mn: String,
) -> String {
  yy <> "-" <> mm <> "-" <> dd <> "T" <> hh <> ":" <> mn <> ":00Z"
}

pub fn parse_optional_float(s: String) -> Option(Float) {
  case s {
    "MM" -> None
    _ -> option.from_result(float.parse(s))
  }
}

pub fn parse_optional_int(s: String) -> Option(Int) {
  case s {
    "MM" -> None
    _ -> option.from_result(int.parse(s))
  }
}

// === JSON encoding ===

/// Serialise a reading to JSON. ingest.gleam wraps this under a
/// per-source key (e.g. "buoy_42036") when writing the aggregate file.
pub fn encode(r: BuoyReading) -> json.Json {
  json.object([
    #("station", json.string(r.station)),
    #("observed_at_utc", json.string(r.observed_at_utc)),
    #("wave_height_m", encode_optional(r.wave_height_m, json.float)),
    #("dominant_period_s", encode_optional(r.dominant_period_s, json.float)),
    #("avg_period_s", encode_optional(r.avg_period_s, json.float)),
    #(
      "mean_wave_direction_deg",
      encode_optional(r.mean_wave_direction_deg, json.int),
    ),
    #("wind_direction_deg", encode_optional(r.wind_direction_deg, json.int)),
    #("wind_speed_ms", encode_optional(r.wind_speed_ms, json.float)),
  ])
}

fn encode_optional(o: Option(a), encode: fn(a) -> json.Json) -> json.Json {
  case o {
    None -> json.null()
    Some(v) -> encode(v)
  }
}
