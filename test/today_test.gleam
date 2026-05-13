//// Snapshot test for the `today.json` payload.
////
//// Hits `today.build_today/9` with hand-built source records so no HTTP
//// fetches happen. The full encoded JSON is snapped via birdie; if the
//// shape changes, `gleam run -m birdie` to review.

import birdie
import dawnpass/score/spots
import dawnpass/sources/ndbc
import dawnpass/sources/noaa_tides
import dawnpass/sources/open_meteo_forecast
import dawnpass/sources/open_meteo_marine
import dawnpass/today
import gleam/json
import gleam/option.{None, Some}

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
    swell_height_m: None,
    swell_period_s: None,
    swell_direction: None,
    wind_wave_height_m: None,
    wind_wave_period_s: None,
    wind_wave_direction: None,
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
    station: "8726347",
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
    wave_height_m: Some(0.2),
    wave_period_s: Some(4.0),
    wave_direction_deg: Some(215),
    sst_c: Some(27.5),
    forecast: [],
  )
}

fn test_wind() -> open_meteo_forecast.WindForecast {
  open_meteo_forecast.WindForecast(
    latitude: 27.685,
    longitude: -82.738,
    observed_at_utc: "2026-05-04T12:00:00Z",
    wind_speed_ms: Some(3.0),
    wind_direction_deg: Some(90),
    air_temp_c: Some(24.0),
    pressure_hpa: Some(1015.0),
    forecast: [],
  )
}

pub fn today_pag_full_sources_test() {
  today.build_today(
    slug: "pag",
    name: "Pass-a-Grille",
    latitude: 27.685,
    longitude: -82.738,
    buoy: Some(test_buoy()),
    tide: Some(test_tide()),
    marine: Some(test_marine()),
    wind: Some(test_wind()),
    spot: spots.pag,
  )
  |> json.to_string
  |> birdie.snap(title: "today pag full sources")
}

pub fn today_pag_no_tide_test() {
  today.build_today(
    slug: "pag",
    name: "Pass-a-Grille",
    latitude: 27.685,
    longitude: -82.738,
    buoy: Some(test_buoy()),
    tide: None,
    marine: Some(test_marine()),
    wind: Some(test_wind()),
    spot: spots.pag,
  )
  |> json.to_string
  |> birdie.snap(title: "today pag without tide")
}

pub fn today_pag_all_silent_test() {
  today.build_today(
    slug: "pag",
    name: "Pass-a-Grille",
    latitude: 27.685,
    longitude: -82.738,
    buoy: None,
    tide: None,
    marine: None,
    wind: None,
    spot: spots.pag,
  )
  |> json.to_string
  |> birdie.snap(title: "today pag all sources silent")
}
