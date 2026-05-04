import dawnpass/ingest
import dawnpass/score/orchestrator as score_orch
import dawnpass/score/spot_config.{type SpotConfig}
import dawnpass/score/spots
import dawnpass/sources/ndbc
import dawnpass/sources/noaa_tides
import dawnpass/sources/open_meteo_forecast
import dawnpass/sources/open_meteo_marine
import dawnpass/wave_spec
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

const buoy_station = "42036"

// Tide station list, tried in order. 8726724 (Clearwater Beach) is the
// Gulf-facing primary, ~20mi N of PAG. 8726520 (St Petersburg, Tampa Bay)
// is the fallback — bay tides lag the open Gulf by ~30-90min through the
// Egmont Key inlet so timing on next-event times will be slightly off
// when the fallback fires, but having a tide line at all beats "—" when
// 8726724 is in maintenance. Future: derive PAG-specific offsets from a
// subordinate station once spots/<spot>.json supports it.
const tide_stations = ["8726724", "8726520"]

// Pass-a-Grille (decimal degrees). Hardcoded until spot configs land.
const pag_lat = 27.685

const pag_lon = -82.738

// Venice South Jetty (decimal degrees). Same offshore swell region as PAG
// but ~85min south by car; the rock jetty produces a meaningfully different
// wave shape on the same model inputs. Shares NDBC 42036 (regional buoy)
// and the PAG tide stations for v1 — the Venice tide gauge sits closer
// (likely 8728690 or similar) and Venice has a ~30-60min phase offset from
// Clearwater Beach. Per-spot tide source is queued as O4.
const venice_lat = 27.073

const venice_lon = -82.456

/// One surf spot's identity for the per-spot ingest loop. `slug` is the
/// short JSON key (e.g. "pag", "venice_south") under which this spot's
/// blocks land in latest.json. `spot_config` is the scoring config (factor
/// breakpoints, verdicts, windows) from src/dawnpass/score/spots.gleam.
pub type Spot {
  Spot(
    slug: String,
    name: String,
    latitude: Float,
    longitude: Float,
    spot_config: SpotConfig,
  )
}

const pag_spot = Spot(
  slug: "pag",
  name: "Pass-a-Grille",
  latitude: pag_lat,
  longitude: pag_lon,
  spot_config: spots.pag,
)

const venice_spot = Spot(
  slug: "venice_south",
  name: "Venice South Jetty",
  latitude: venice_lat,
  longitude: venice_lon,
  spot_config: spots.venice_south,
)

// Order matters: this is also the JSON serialisation order under
// `spots.<slug>` and the rendering order on the static page (PAG first,
// Venice below). Keep PAG first as the daily ritual primary spot.
const spots_list: List(Spot) = [pag_spot, venice_spot]

const data_path = "public/data/latest.json"

const index_template_path = "public/index.template.html"

const index_output_path = "public/index.html"

pub fn main() -> Nil {
  io.println("dawnpass · the watch is up")

  let buoy_opt = log_buoy(ndbc.fetch_buoy(buoy_station))
  let tide_opt = log_tide(noaa_tides.fetch_tide_with_fallback(tide_stations))
  let marine_opt =
    log_marine(open_meteo_marine.fetch_marine(
      latitude: pag_lat,
      longitude: pag_lon,
    ))
  let wind_opt =
    log_wind(open_meteo_forecast.fetch_wind(
      latitude: pag_lat,
      longitude: pag_lon,
    ))

  let buoy_block = case buoy_opt {
    Some(r) -> [#("buoy_" <> r.station, ndbc.encode(r))]
    None -> []
  }
  let tide_block = case tide_opt {
    Some(r) -> [#("tide_" <> r.station, noaa_tides.encode(r))]
    None -> []
  }
  let marine_block = case marine_opt {
    Some(r) -> [#("marine_pag", open_meteo_marine.encode(r))]
    None -> []
  }
  let wind_block = case wind_opt {
    Some(r) -> [#("wind_pag", open_meteo_forecast.encode(r))]
    None -> []
  }

  // Computed wave layer block — derived from buoy + marine via wave_spec.
  // Always emitted (Silent when both sources are wave-null) so the renderer
  // can rely on `data.wave` being present.
  let wave_layers = wave_spec.compute_layers(buoy_opt, marine_opt, wind_opt)
  let wave_block = [#("wave", wave_spec.encode(wave_layers))]

  // Scoring + window detection. Always emitted (the page can read it
  // regardless of which sources succeeded).
  let score_block = [
    #(
      "score",
      score_orch.build_block(
        buoy_opt,
        tide_opt,
        marine_opt,
        wind_opt,
        spots.pag,
      ),
    ),
  ]

  let blocks: List(#(String, json.Json)) =
    list.flatten([
      buoy_block,
      tide_block,
      marine_block,
      wind_block,
      wave_block,
      score_block,
    ])

  case ingest.write_latest(blocks, to: data_path) {
    Ok(_) -> io.println("wrote " <> data_path)
    Error(e) -> io.println("write failed: " <> string.inspect(e))
  }

  // SSR the wave-layer paths into index.html so first paint is correct
  // without JS. JS still mounts on top to animate.
  case
    ingest.write_index(
      wave_layers,
      template: index_template_path,
      output: index_output_path,
    )
  {
    Ok(_) -> io.println("wrote " <> index_output_path)
    Error(e) -> io.println("index write failed: " <> string.inspect(e))
  }
}

fn log_buoy(
  res: Result(ndbc.BuoyReading, ndbc.NdbcError),
) -> Option(ndbc.BuoyReading) {
  case res {
    Ok(r) -> {
      io.println("buoy " <> r.station <> " · " <> r.observed_at_utc)
      io.println(string.inspect(r))
      Some(r)
    }
    Error(e) -> {
      io.println("ndbc fetch failed: " <> string.inspect(e))
      None
    }
  }
}

fn log_tide(
  res: Result(noaa_tides.TideReading, noaa_tides.TideError),
) -> Option(noaa_tides.TideReading) {
  case res {
    Ok(r) -> {
      io.println("tide " <> r.station <> " · " <> r.observed_at_utc)
      io.println(string.inspect(r))
      Some(r)
    }
    Error(e) -> {
      io.println("noaa fetch failed: " <> string.inspect(e))
      None
    }
  }
}

fn log_marine(
  res: Result(open_meteo_marine.MarineReading, open_meteo_marine.MarineError),
) -> Option(open_meteo_marine.MarineReading) {
  case res {
    Ok(r) -> {
      io.println("marine pag · " <> r.observed_at_utc)
      io.println(string.inspect(r))
      Some(r)
    }
    Error(e) -> {
      io.println("open-meteo marine fetch failed: " <> string.inspect(e))
      None
    }
  }
}

fn log_wind(
  res: Result(
    open_meteo_forecast.WindForecast,
    open_meteo_forecast.ForecastError,
  ),
) -> Option(open_meteo_forecast.WindForecast) {
  case res {
    Ok(r) -> {
      io.println("wind pag · " <> r.observed_at_utc)
      Some(r)
    }
    Error(e) -> {
      io.println(
        "open-meteo forecast (wind) fetch failed: " <> string.inspect(e),
      )
      None
    }
  }
}
