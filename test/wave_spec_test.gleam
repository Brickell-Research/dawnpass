//// Snapshot tests for the wave-mapping math layer.
////
//// Each test feeds compute_layers a hand-built BuoyReading + MarineReading
//// and snapshots the encoded JSON. The numbers here ARE the spec — when a
//// formula changes, the snapshot diff makes the change explicit before
//// it ships.

import birdie
import dawnpass/sources/ndbc.{type BuoyReading, BuoyReading}
import dawnpass/sources/open_meteo_marine.{type MarineReading, MarineReading}
import dawnpass/wave_spec
import gleam/json
import gleam/option.{None, Some}

// === Fixture readings ===

fn buoy(
  hs hs: option.Option(Float),
  tp tp: option.Option(Float),
  tm tm: option.Option(Float),
  dir dir: option.Option(Int),
  ws ws: option.Option(Float),
) -> BuoyReading {
  BuoyReading(
    station: "42036",
    observed_at_utc: "2026-05-03T17:50:00Z",
    wave_height_m: hs,
    dominant_period_s: tp,
    avg_period_s: tm,
    mean_wave_direction_deg: dir,
    wind_direction_deg: Some(30),
    wind_speed_ms: ws,
  )
}

fn marine(
  hs hs: option.Option(Float),
  tp tp: option.Option(Float),
  dir dir: option.Option(Int),
) -> MarineReading {
  MarineReading(
    latitude: 27.685,
    longitude: -82.738,
    observed_at_utc: "2026-05-03T17:50:00Z",
    wave_height_m: hs,
    wave_period_s: tp,
    wave_direction_deg: dir,
    forecast: [],
  )
}

fn snap(layers: wave_spec.WaveLayers, title: String) -> Nil {
  layers
  |> wave_spec.encode
  |> json.to_string
  |> birdie.snap(title:)
}

// === Tests ===

pub fn buoy_with_full_divergence_test() {
  // Hs=0.8m, Tp=8s, Tm=4s — mean diverges from swell. Wind 9 m/s → chop on.
  let b = buoy(Some(0.8), Some(8.0), Some(4.0), Some(250), Some(9.0))
  let m = marine(Some(0.44), Some(4.15), Some(325))
  wave_spec.compute_layers(Some(b), Some(m))
  |> snap("wave_spec: buoy with Tp/Tm divergence")
}

pub fn buoy_without_tm_collapses_test() {
  // Buoy has Hs/Tp but no avg_period — mean reuses Tp, collapses on swell.
  let b = buoy(Some(0.6), Some(6.0), None, Some(225), Some(7.0))
  wave_spec.compute_layers(Some(b), None)
  |> snap("wave_spec: buoy without Tm collapses mean onto swell")
}

pub fn marine_fallback_when_buoy_silent_test() {
  // Buoy waves null but wind present — picker falls through to marine.
  // Mean collapses (no marine Tm). Chop still uses buoy wind.
  let b = buoy(None, None, None, None, Some(8.0))
  let m = marine(Some(0.44), Some(4.15), Some(325))
  wave_spec.compute_layers(Some(b), Some(m))
  |> snap("wave_spec: marine fallback when buoy wave-silent")
}

pub fn all_silent_test() {
  // Both sources null on waves — Silent state, all amps 0, periods None.
  let b = buoy(None, None, None, None, Some(8.0))
  let m = marine(None, None, None)
  wave_spec.compute_layers(Some(b), Some(m))
  |> snap("wave_spec: all sources silent on waves")
}

pub fn calm_wind_drops_chop_test() {
  // Wind speed at 1.5 m/s is below the 3 m/s threshold — chop amp = 0.
  let b = buoy(Some(0.6), Some(6.0), Some(5.0), Some(180), Some(1.5))
  wave_spec.compute_layers(Some(b), None)
  |> snap("wave_spec: wind under 3 m/s drops chop layer")
}

pub fn direction_falls_through_to_marine_test() {
  // Buoy has waves but no direction — direction picker should fall through
  // to marine's wave_direction_deg.
  let b = buoy(Some(0.8), Some(8.0), Some(4.0), None, Some(9.0))
  let m = marine(Some(0.44), Some(4.15), Some(325))
  wave_spec.compute_layers(Some(b), Some(m))
  |> snap("wave_spec: direction falls through to marine when buoy null")
}

pub fn clamp_boundaries_test() {
  // Hs of 5m would amplify to 150 (way above swell_amp_max=45). Tp of 0.5s
  // would shrink lambda below 60. Verify both bounds enforce.
  let b = buoy(Some(5.0), Some(0.5), Some(0.5), Some(0), Some(50.0))
  wave_spec.compute_layers(Some(b), None)
  |> snap("wave_spec: amplitudes and wavelengths respect clamp bounds")
}
