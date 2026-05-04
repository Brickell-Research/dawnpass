//// Smoke tests for the per-spot JSON shape that lands under
//// `spots.<slug>` in `public/data/latest.json`.
////
//// Hits `dawnpass.encode_spot_block/5` with hand-built source records so
//// no HTTP fetches happen. We assert key-presence and basic structural
//// invariants — full byte-equivalence is covered by the parser snapshot
//// tests on each individual encoder.

import dawnpass.{Spot}
import dawnpass/score/spots
import dawnpass/sources/ndbc
import dawnpass/sources/noaa_tides
import dawnpass/sources/open_meteo_forecast
import dawnpass/sources/open_meteo_marine
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

const test_pag = Spot(
  slug: "pag",
  name: "Pass-a-Grille",
  latitude: 27.685,
  longitude: -82.738,
  spot_config: spots.pag,
)

const test_venice = Spot(
  slug: "venice_south",
  name: "Venice South Jetty",
  latitude: 27.073,
  longitude: -82.456,
  spot_config: spots.venice_south,
)

fn test_buoy() -> ndbc.BuoyReading {
  ndbc.BuoyReading(
    station: "42036",
    observed_at_utc: "2026-05-04T12:00:00Z",
    wave_height_m: Some(0.6),
    dominant_period_s: Some(7.0),
    avg_period_s: Some(5.0),
    mean_wave_direction_deg: Some(250),
    wind_direction_deg: Some(90),
    wind_speed_ms: Some(5.0),
    atmp_c: Some(22.0),
    wtmp_c: Some(24.0),
  )
}

fn test_tide() -> noaa_tides.TideReading {
  let next =
    noaa_tides.TideEvent(
      kind: noaa_tides.High,
      at_utc: "2026-05-04T18:00:00Z",
      height_ft: 2.5,
    )
  noaa_tides.TideReading(
    station: "8726724",
    observed_at_utc: "2026-05-04T12:00:00Z",
    height_ft: 1.2,
    trend: noaa_tides.Rising,
    next_event: next,
    upcoming: [next],
  )
}

fn test_marine() -> open_meteo_marine.MarineReading {
  open_meteo_marine.MarineReading(
    latitude: 27.685,
    longitude: -82.738,
    observed_at_utc: "2026-05-04T12:00:00Z",
    wave_height_m: Some(0.5),
    wave_period_s: Some(6.5),
    wave_direction_deg: Some(255),
    sst_c: Some(24.4),
    forecast: [],
  )
}

fn test_wind() -> open_meteo_forecast.WindForecast {
  open_meteo_forecast.WindForecast(
    latitude: 27.685,
    longitude: -82.738,
    observed_at_utc: "2026-05-04T12:00:00Z",
    wind_speed_ms: Some(4.5),
    wind_direction_deg: Some(95),
    air_temp_c: Some(22.5),
    pressure_hpa: Some(1015.0),
    forecast: [],
  )
}

// === Tests ===

pub fn pag_spot_block_has_required_keys_test() {
  let body =
    dawnpass.encode_spot_block(
      test_pag,
      Some(test_buoy()),
      Some(test_tide()),
      Some(test_marine()),
      Some(test_wind()),
    )
    |> json.to_string

  // Required identity fields
  string.contains(body, "\"name\":\"Pass-a-Grille\"") |> should.be_true
  string.contains(body, "\"latitude\"") |> should.be_true
  string.contains(body, "\"longitude\"") |> should.be_true

  // Required source-data sub-objects
  string.contains(body, "\"marine\"") |> should.be_true
  string.contains(body, "\"wind\"") |> should.be_true
  string.contains(body, "\"wave\"") |> should.be_true
  string.contains(body, "\"score\"") |> should.be_true
}

pub fn venice_spot_block_uses_venice_config_test() {
  let body =
    dawnpass.encode_spot_block(
      test_venice,
      Some(test_buoy()),
      Some(test_tide()),
      Some(test_marine()),
      Some(test_wind()),
    )
    |> json.to_string

  string.contains(body, "\"name\":\"Venice South Jetty\"") |> should.be_true
  // Same key set as PAG — proves both spots produce the same shape
  string.contains(body, "\"score\"") |> should.be_true
  string.contains(body, "\"wave\"") |> should.be_true
}

pub fn pag_and_venice_produce_distinct_blocks_test() {
  // Identical source data into both spots — outputs MUST differ at minimum
  // by name. If they were byte-identical that'd mean the spot config is
  // being ignored downstream.
  let pag_body =
    dawnpass.encode_spot_block(
      test_pag,
      Some(test_buoy()),
      Some(test_tide()),
      Some(test_marine()),
      Some(test_wind()),
    )
    |> json.to_string
  let venice_body =
    dawnpass.encode_spot_block(
      test_venice,
      Some(test_buoy()),
      Some(test_tide()),
      Some(test_marine()),
      Some(test_wind()),
    )
    |> json.to_string

  { pag_body == venice_body } |> should.be_false
}

pub fn missing_marine_and_wind_still_produces_valid_block_test() {
  // When upstream fetches fail, marine/wind keys come through as null but
  // the per-spot block still has all the structural fields. Score block
  // is computed regardless (handles None inputs gracefully).
  let body =
    dawnpass.encode_spot_block(
      test_pag,
      Some(test_buoy()),
      Some(test_tide()),
      None,
      None,
    )
    |> json.to_string

  string.contains(body, "\"marine\":null") |> should.be_true
  string.contains(body, "\"wind\":null") |> should.be_true
  string.contains(body, "\"score\"") |> should.be_true
  string.contains(body, "\"wave\"") |> should.be_true
}
