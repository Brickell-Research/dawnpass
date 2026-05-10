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
    /// Air temperature at the buoy (Celsius). Offshore reading; for
    /// surfer-relevant air temp prefer Open-Meteo `temperature_2m`.
    atmp_c: Option(Float),
    /// Water (sea-surface) temperature at the buoy (Celsius). Offshore;
    /// close enough to beach water in the Gulf for surf decisions.
    wtmp_c: Option(Float),
    /// From the .spec spectral feed: primary swell component height,
    /// distinct from `wave_height_m` (which is the significant height of
    /// the *combined* sea — swell + wind wave together).
    swell_height_m: Option(Float),
    swell_period_s: Option(Float),
    /// Cardinal compass text from .spec ("S", "WSW", "NNE"…). NDBC
    /// publishes swell direction as a category, not degrees, in the
    /// spectral feed.
    swell_direction: Option(String),
    /// From the .spec spectral feed: locally-generated wind-wave
    /// component. On the inner Gulf this is usually the dominant
    /// signal — short-period, downwind direction.
    wind_wave_height_m: Option(Float),
    wind_wave_period_s: Option(Float),
    wind_wave_direction: Option(String),
  )
}

/// Intermediate row from the .spec spectral feed; merged into a
/// BuoyReading by `merge_spec`.
pub type BuoySpec {
  BuoySpec(
    observed_at_utc: String,
    wave_height_m: Option(Float),
    swell_height_m: Option(Float),
    swell_period_s: Option(Float),
    swell_direction: Option(String),
    wind_wave_height_m: Option(Float),
    wind_wave_period_s: Option(Float),
    wind_wave_direction: Option(String),
    avg_period_s: Option(Float),
    mean_wave_direction_deg: Option(Int),
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

/// Fetch the most recent reading from NDBC's realtime2 feed for a station,
/// merging the standard met file (.txt — wind/temp/pressure/combined waves)
/// with the spectral file (.spec — swell/wind-wave breakdown). Spec failures
/// are non-fatal: if the spec fetch errors, the standard reading is returned
/// with the spec component fields left as None.
pub fn fetch_buoy(station: String) -> Result(BuoyReading, NdbcError) {
  use reading <- result.try(fetch_realtime2(station))
  case fetch_spec(station) {
    Ok(spec) -> Ok(merge_spec(reading, spec))
    Error(_) -> Ok(reading)
  }
}

fn fetch_realtime2(station: String) -> Result(BuoyReading, NdbcError) {
  use body <- result.try(get(realtime2_base <> station <> ".txt"))
  parse_realtime2_body(station, body)
}

fn fetch_spec(station: String) -> Result(BuoySpec, NdbcError) {
  use body <- result.try(get(realtime2_base <> station <> ".spec"))
  parse_spec_body(body)
}

fn get(url: String) -> Result(String, NdbcError) {
  use base_req <- result.try(
    request.to(url) |> result.replace_error(InvalidUrl(url)),
  )
  let req = request.set_header(base_req, "user-agent", user_agent)
  use resp <- result.try(httpc.send(req) |> result.map_error(HttpError))
  Ok(resp.body)
}

/// Overlay spec values onto a BuoyReading. Always sets the spec-only
/// component fields (swell_*, wind_wave_*). Falls back to spec for
/// `wave_height_m`, `avg_period_s`, `mean_wave_direction_deg` only when
/// the standard met file had them missing — the standard feed is the
/// canonical source for those when present.
pub fn merge_spec(r: BuoyReading, s: BuoySpec) -> BuoyReading {
  BuoyReading(
    ..r,
    wave_height_m: option.or(r.wave_height_m, s.wave_height_m),
    avg_period_s: option.or(r.avg_period_s, s.avg_period_s),
    mean_wave_direction_deg: option.or(
      r.mean_wave_direction_deg,
      s.mean_wave_direction_deg,
    ),
    swell_height_m: s.swell_height_m,
    swell_period_s: s.swell_period_s,
    swell_direction: s.swell_direction,
    wind_wave_height_m: s.wind_wave_height_m,
    wind_wave_period_s: s.wind_wave_period_s,
    wind_wave_direction: s.wind_wave_direction,
  )
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

  // Cols 12-14 are PRES, ATMP, WTMP. We grab ATMP + WTMP and ignore PRES.
  // Older buoys without atmospheric sensors return rows with only the wave
  // columns; the extended pattern falls through and we set both temps None.
  case cols {
    [
      yy,
      mm,
      dd,
      hh,
      mn,
      wdir,
      wspd,
      _gst,
      wvht,
      dpd,
      apd,
      mwd,
      _pres,
      atmp,
      wtmp,
      ..
    ] ->
      Ok(BuoyReading(
        station:,
        observed_at_utc: iso_timestamp(yy, mm, dd, hh, mn),
        wave_height_m: parse_optional_float(wvht),
        dominant_period_s: parse_optional_float(dpd),
        avg_period_s: parse_optional_float(apd),
        mean_wave_direction_deg: parse_optional_int(mwd),
        wind_direction_deg: parse_optional_int(wdir),
        wind_speed_ms: parse_optional_float(wspd),
        atmp_c: parse_optional_float(atmp),
        wtmp_c: parse_optional_float(wtmp),
        swell_height_m: None,
        swell_period_s: None,
        swell_direction: None,
        wind_wave_height_m: None,
        wind_wave_period_s: None,
        wind_wave_direction: None,
      ))
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
        atmp_c: None,
        wtmp_c: None,
        swell_height_m: None,
        swell_period_s: None,
        swell_direction: None,
        wind_wave_height_m: None,
        wind_wave_period_s: None,
        wind_wave_direction: None,
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

pub fn parse_optional_string(s: String) -> Option(String) {
  case s {
    "MM" -> None
    _ -> Some(s)
  }
}

// NDBC .spec column layout (whitespace-separated, "MM" = missing):
//   0  YY    year                     8  WWH  wind wave height, m
//   1  MM    month                    9  WWP  wind wave period, s
//   2  DD    day                     10  SwD  swell direction (cardinal)
//   3  hh    hour UTC                11  WWD  wind wave dir (cardinal)
//   4  mm    minute UTC              12  STEEPNESS (text, e.g. AVERAGE)
//   5  WVHT  combined sig height, m  13  APD  average period, s
//   6  SwH   swell component, m      14  MWD  mean wave direction, degT
//   7  SwP   swell period, s
//
// Direction columns are cardinal text ("S", "WSW") in the spec feed even
// though the header says "degT" — NDBC publishes them as categories for
// surfer-readable output.

/// Strip header rows and parse the most recent data row of a .spec body.
pub fn parse_spec_body(body: String) -> Result(BuoySpec, NdbcError) {
  let data_rows =
    body
    |> string.split("\n")
    |> list.filter(fn(l) { !string.starts_with(l, "#") && string.trim(l) != "" })

  case data_rows {
    [latest, ..] -> parse_spec_row(latest)
    [] -> Error(ParseError("no .spec data rows"))
  }
}

pub fn parse_spec_row(row: String) -> Result(BuoySpec, NdbcError) {
  let cols =
    row
    |> string.split(" ")
    |> list.filter(fn(c) { c != "" })

  case cols {
    [
      yy,
      mm,
      dd,
      hh,
      mn,
      wvht,
      swh,
      swp,
      wwh,
      wwp,
      swd,
      wwd,
      _steepness,
      apd,
      mwd,
      ..
    ] ->
      Ok(BuoySpec(
        observed_at_utc: iso_timestamp(yy, mm, dd, hh, mn),
        wave_height_m: parse_optional_float(wvht),
        swell_height_m: parse_optional_float(swh),
        swell_period_s: parse_optional_float(swp),
        swell_direction: parse_optional_string(swd),
        wind_wave_height_m: parse_optional_float(wwh),
        wind_wave_period_s: parse_optional_float(wwp),
        wind_wave_direction: parse_optional_string(wwd),
        avg_period_s: parse_optional_float(apd),
        mean_wave_direction_deg: parse_optional_int(mwd),
      ))
    _ -> Error(ParseError("unexpected NDBC .spec row: " <> row))
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
    #("atmp_c", encode_optional(r.atmp_c, json.float)),
    #("wtmp_c", encode_optional(r.wtmp_c, json.float)),
    #("swell_height_m", encode_optional(r.swell_height_m, json.float)),
    #("swell_period_s", encode_optional(r.swell_period_s, json.float)),
    #("swell_direction", encode_optional(r.swell_direction, json.string)),
    #("wind_wave_height_m", encode_optional(r.wind_wave_height_m, json.float)),
    #("wind_wave_period_s", encode_optional(r.wind_wave_period_s, json.float)),
    #(
      "wind_wave_direction",
      encode_optional(r.wind_wave_direction, json.string),
    ),
  ])
}

fn encode_optional(o: Option(a), encode: fn(a) -> json.Json) -> json.Json {
  case o {
    None -> json.null()
    Some(v) -> encode(v)
  }
}
