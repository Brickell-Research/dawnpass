//// NOAA Tides & Currents source.
////
//// Two HTTP calls to api.tidesandcurrents.noaa.gov:
////   1. product=water_level, date=latest  → most recent observed height
////   2. product=predictions, interval=hilo → upcoming high/low events
////
//// Trend is derived from the next event: the one after "now" tells us
//// whether we're rising (next is High), falling (next is Low), or
//// near slack (the event is within `slack_threshold_minutes`).
////
//// Pure parsing helpers are pub so a future test module can hit them
//// with fixture JSON without a live network call.

import gleam/dynamic/decode
import gleam/float
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/order
import gleam/result
import gleam/string

// === System time helper (Erlang `calendar:universal_time/0`) ===
//
// Used by the predictions-only path to anchor "now" when the station has
// no real-time gauge to provide a timestamp. Returns the current UTC time
// as a calendar tuple; we format to ISO 8601 for compatibility with the
// rest of the timestamp pipeline.
@external(erlang, "calendar", "universal_time")
fn calendar_universal_time() -> #(#(Int, Int, Int), #(Int, Int, Int))

fn now_utc_iso() -> String {
  let #(#(y, m, d), #(h, mi, s)) = calendar_universal_time()
  pad4(y)
  <> "-"
  <> pad2(m)
  <> "-"
  <> pad2(d)
  <> "T"
  <> pad2(h)
  <> ":"
  <> pad2(mi)
  <> ":"
  <> pad2(s)
  <> "Z"
}

fn pad2(n: Int) -> String {
  case n < 10 {
    True -> "0" <> int.to_string(n)
    False -> int.to_string(n)
  }
}

fn pad4(n: Int) -> String {
  case n < 10, n < 100, n < 1000 {
    True, _, _ -> "000" <> int.to_string(n)
    _, True, _ -> "00" <> int.to_string(n)
    _, _, True -> "0" <> int.to_string(n)
    _, _, _ -> int.to_string(n)
  }
}

// === Linear interpolation between hi/lo events ===
//
// For predictions-only stations, derive the current water height by
// interpolating linearly between the most recent past event and the next
// future event. Linear is ~5% off true sinusoidal but the surfline-line
// shows one decimal of feet; the error is in the second decimal.
fn interpolate_level(
  now_iso: String,
  events: List(TideEvent),
  next: TideEvent,
) -> Float {
  let past =
    events
    |> list.filter(fn(e) { string.compare(e.at_utc, now_iso) != order.Gt })
    |> list.last
  case past {
    Ok(prev) -> {
      let total = abs_minutes_between(prev.at_utc, next.at_utc)
      let elapsed = abs_minutes_between(prev.at_utc, now_iso)
      let frac = case total {
        0 -> 0.0
        _ -> int.to_float(elapsed) /. int.to_float(total)
      }
      prev.height_ft +. { next.height_ft -. prev.height_ft } *. frac
    }
    // No past event in window — fall back to the next event's height.
    // Slight visual lag but better than 0.0 on the page.
    Error(_) -> next.height_ft
  }
}

fn abs_minutes_between(a_iso: String, b_iso: String) -> Int {
  case to_minutes_since_epoch(a_iso), to_minutes_since_epoch(b_iso) {
    Ok(a), Ok(b) -> int.absolute_value(b - a)
    _, _ -> 0
  }
}

// "2026-05-04T12:34:00Z" → minutes since 0000-01-01 (calendar arithmetic
// in Erlang's calendar:datetime_to_gregorian_seconds/1).
fn to_minutes_since_epoch(iso: String) -> Result(Int, Nil) {
  use y <- result.try(int.parse(string.slice(iso, 0, 4)))
  use m <- result.try(int.parse(string.slice(iso, 5, 2)))
  use d <- result.try(int.parse(string.slice(iso, 8, 2)))
  use h <- result.try(int.parse(string.slice(iso, 11, 2)))
  use mi <- result.try(int.parse(string.slice(iso, 14, 2)))
  let secs = datetime_to_gregorian_seconds(#(#(y, m, d), #(h, mi, 0)))
  Ok(secs / 60)
}

@external(erlang, "calendar", "datetime_to_gregorian_seconds")
fn datetime_to_gregorian_seconds(
  dt: #(#(Int, Int, Int), #(Int, Int, Int)),
) -> Int

pub type TideReading {
  TideReading(
    station: String,
    observed_at_utc: String,
    height_ft: Float,
    trend: Trend,
    next_event: TideEvent,
    /// All hi/lo events from the prediction window whose timestamp is
    /// after `observed_at_utc`. Sorted chronologically. The frontend
    /// uses this to render per-day tide rows in the outlook strip.
    upcoming: List(TideEvent),
  )
}

pub type Trend {
  Rising
  Falling
  Slack
}

pub type TideEvent {
  TideEvent(kind: TideEventKind, at_utc: String, height_ft: Float)
}

pub type TideEventKind {
  High
  Low
}

pub type TideError {
  HttpError(httpc.HttpError)
  InvalidUrl(String)
  JsonDecodeError(json.DecodeError)
  ParseError(String)
}

const api_base = "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter"

const user_agent = "dawnpass/0.1 (https://dawnpass.brickellresearch.org)"

// "Near a high/low event" — used to flag Slack tide.
const slack_threshold_minutes = 30

// === HTTP fetch ===

/// Try each station in order; return the first successful TideReading.
/// If every station fails, surfaces the last error encountered. For each
/// station, tries the primary path (observed water level + hi/lo) first,
/// then falls back to the predictions-only path (interpolate level from
/// hi/lo events) for subordinate stations like Venice Inlet (8725889) that
/// only ship harmonic predictions, no real-time gauge.
pub fn fetch_tide_with_fallback(
  stations: List(String),
) -> Result(TideReading, TideError) {
  case stations {
    [] -> Error(ParseError("no tide stations configured"))
    [station, ..rest] ->
      case fetch_tide(station) {
        Ok(reading) -> Ok(reading)
        Error(_) ->
          case fetch_tide_predictions_only(station) {
            Ok(reading) -> Ok(reading)
            Error(_) ->
              case rest {
                [] -> fetch_tide(station)
                _ -> fetch_tide_with_fallback(rest)
              }
          }
      }
  }
}

/// Fetch the most recent observed water level + the upcoming hi/lo
/// predictions for a NOAA tide station, then derive the trend. Works for
/// primary stations with real-time water-level gauges; subordinate
/// stations (predictions-only) fail here and route to
/// `fetch_tide_predictions_only/1`.
pub fn fetch_tide(station: String) -> Result(TideReading, TideError) {
  use level <- result.try(fetch_water_level(station))
  // Use the level's timestamp as the begin_date for the hi/lo query so
  // the 5-day window is anchored to "now" (NOAA's date=today returns only
  // today's calendar-day events, which fails after the day's last event).
  use events <- result.try(fetch_hilo(
    station,
    yyyymmdd_from_iso(level.observed_at_utc),
  ))
  use next <- result.try(pick_next_event(level.observed_at_utc, events))
  let upcoming =
    list.filter(events, fn(e) {
      string.compare(e.at_utc, level.observed_at_utc) == order.Gt
    })
  Ok(TideReading(
    station:,
    observed_at_utc: level.observed_at_utc,
    height_ft: level.height_ft,
    trend: compute_trend(level.observed_at_utc, next),
    next_event: next,
    upcoming:,
  ))
}

/// Predictions-only path for subordinate stations (Venice Inlet 8725889,
/// Siesta Key 8726034, etc.) which ship hi/lo harmonic predictions but no
/// real-time observed water level. Anchors at current UTC, picks the next
/// future event, and linearly interpolates the current height between the
/// most recent past event and the next one. Linear interp is ~5% off true
/// sinusoidal but adequate for the glanceable surf line.
pub fn fetch_tide_predictions_only(
  station: String,
) -> Result(TideReading, TideError) {
  let now = now_utc_iso()
  use events <- result.try(fetch_hilo(station, yyyymmdd_from_iso(now)))
  use next <- result.try(pick_next_event(now, events))
  let upcoming =
    list.filter(events, fn(e) { string.compare(e.at_utc, now) == order.Gt })
  let height_ft = interpolate_level(now, events, next)
  Ok(TideReading(
    station:,
    observed_at_utc: now,
    height_ft:,
    trend: compute_trend(now, next),
    next_event: next,
    upcoming:,
  ))
}

// "2026-05-03T19:42:00Z" → "20260503". Strips dashes from the ISO date.
fn yyyymmdd_from_iso(iso: String) -> String {
  string.slice(iso, 0, 4) <> string.slice(iso, 5, 2) <> string.slice(iso, 8, 2)
}

pub type WaterLevel {
  WaterLevel(observed_at_utc: String, height_ft: Float)
}

fn fetch_water_level(station: String) -> Result(WaterLevel, TideError) {
  let url =
    api_base
    <> "?product=water_level"
    <> "&station="
    <> station
    <> "&date=latest"
    <> "&datum=MLLW"
    <> "&units=english"
    <> "&time_zone=gmt"
    <> "&format=json"
  use body <- result.try(get(url))
  parse_water_level(body)
}

fn fetch_hilo(
  station: String,
  begin_date: String,
) -> Result(List(TideEvent), TideError) {
  let url =
    api_base
    <> "?product=predictions"
    <> "&station="
    <> station
    <> "&begin_date="
    <> begin_date
    <> "&range=120"
    <> "&datum=MLLW"
    <> "&units=english"
    <> "&interval=hilo"
    <> "&time_zone=gmt"
    <> "&format=json"
  use body <- result.try(get(url))
  parse_hilo(body)
}

fn get(url: String) -> Result(String, TideError) {
  use base_req <- result.try(
    request.to(url)
    |> result.replace_error(InvalidUrl(url)),
  )
  let req = request.set_header(base_req, "user-agent", user_agent)
  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(HttpError),
  )
  Ok(resp.body)
}

// === pure parsing (testable) ===

/// Parse a NOAA water_level response. Picks the most recent entry.
pub fn parse_water_level(body: String) -> Result(WaterLevel, TideError) {
  let entry = {
    use t <- decode.field("t", decode.string)
    use v <- decode.field("v", decode.string)
    decode.success(#(t, v))
  }
  let decoder = {
    use data <- decode.field("data", decode.list(entry))
    decode.success(data)
  }
  case json.parse(body, decoder) {
    Error(e) -> Error(JsonDecodeError(e))
    Ok([]) -> Error(ParseError("water_level: empty data"))
    Ok([#(t, v_str), ..]) ->
      case float.parse(v_str) {
        Error(_) -> Error(ParseError("water_level: bad float: " <> v_str))
        Ok(v) ->
          Ok(WaterLevel(observed_at_utc: normalize_timestamp(t), height_ft: v))
      }
  }
}

/// Parse a NOAA predictions(hilo) response into TideEvents.
pub fn parse_hilo(body: String) -> Result(List(TideEvent), TideError) {
  let entry = {
    use t <- decode.field("t", decode.string)
    use v <- decode.field("v", decode.string)
    use kind <- decode.field("type", decode.string)
    decode.success(#(t, v, kind))
  }
  let decoder = {
    use predictions <- decode.field("predictions", decode.list(entry))
    decode.success(predictions)
  }
  case json.parse(body, decoder) {
    Error(e) -> Error(JsonDecodeError(e))
    Ok(rows) -> {
      let events =
        list.filter_map(rows, fn(row) {
          let #(t, v_str, kind_str) = row
          case float.parse(v_str), parse_kind(kind_str) {
            Ok(v), Ok(k) ->
              Ok(TideEvent(
                kind: k,
                at_utc: normalize_timestamp(t),
                height_ft: v,
              ))
            _, _ -> Error(Nil)
          }
        })
      case events {
        [] -> Error(ParseError("hilo: no parseable events"))
        _ -> Ok(events)
      }
    }
  }
}

fn parse_kind(s: String) -> Result(TideEventKind, Nil) {
  case s {
    "H" -> Ok(High)
    "L" -> Ok(Low)
    _ -> Error(Nil)
  }
}

/// First event whose timestamp is strictly after `now_iso`.
/// Relies on ISO timestamps being lexicographically ordered.
pub fn pick_next_event(
  now_iso: String,
  events: List(TideEvent),
) -> Result(TideEvent, TideError) {
  case
    list.find(events, fn(e) { string.compare(e.at_utc, now_iso) == order.Gt })
  {
    Ok(e) -> Ok(e)
    Error(_) -> Error(ParseError("no future hi/lo event in prediction window"))
  }
}

/// Rising/Falling from the kind of the next event; Slack if event is close.
pub fn compute_trend(now_iso: String, next: TideEvent) -> Trend {
  case minutes_until(now_iso, next.at_utc) {
    diff if diff <= slack_threshold_minutes -> Slack
    _ ->
      case next.kind {
        High -> Rising
        Low -> Falling
      }
  }
}

/// Crude minutes-between for two ISO-like timestamps. Both must be the
/// "YYYY-MM-DDTHH:MM:00Z" shape we normalise to. Returns 0 on parse fail.
pub fn minutes_until(now_iso: String, then_iso: String) -> Int {
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
  // "2026-05-03T17:30:00Z" — pluck Y, M, D, h, m as ints and fold to a
  // monotonically increasing minute count. Good enough for diffs within
  // the next ~24h; not a real calendar.
  case string.length(iso) >= 16 {
    False -> Error(Nil)
    True -> {
      use yyyy <- result.try(int.parse(string.slice(iso, 0, 4)))
      use mo <- result.try(int.parse(string.slice(iso, 5, 2)))
      use dd <- result.try(int.parse(string.slice(iso, 8, 2)))
      use hh <- result.try(int.parse(string.slice(iso, 11, 2)))
      use mm <- result.try(int.parse(string.slice(iso, 14, 2)))
      Ok({ { { { yyyy * 12 + mo } * 31 + dd } * 24 + hh } * 60 + mm })
    }
  }
}

/// "2026-05-03 17:30" → "2026-05-03T17:30:00Z". Idempotent for already-ISO inputs.
pub fn normalize_timestamp(s: String) -> String {
  case string.split(s, " ") {
    [date, time] -> date <> "T" <> time <> ":00Z"
    _ -> s
  }
}

// === JSON encoding ===

/// Serialise a tide reading. ingest.gleam wraps under "tide_<station>".
pub fn encode(r: TideReading) -> json.Json {
  json.object([
    #("station", json.string(r.station)),
    #("observed_at_utc", json.string(r.observed_at_utc)),
    #("height_ft", json.float(r.height_ft)),
    #("trend", json.string(encode_trend(r.trend))),
    #("next_event", encode_event(r.next_event)),
    #("upcoming", json.array(r.upcoming, of: encode_event)),
  ])
}

fn encode_trend(t: Trend) -> String {
  case t {
    Rising -> "rising"
    Falling -> "falling"
    Slack -> "slack"
  }
}

fn encode_event(e: TideEvent) -> json.Json {
  json.object([
    #("kind", json.string(encode_kind(e.kind))),
    #("at_utc", json.string(e.at_utc)),
    #("height_ft", json.float(e.height_ft)),
  ])
}

fn encode_kind(k: TideEventKind) -> String {
  case k {
    High -> "high"
    Low -> "low"
  }
}
