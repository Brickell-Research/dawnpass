import dawnpass/ingest
import dawnpass/score/orchestrator as score_orch
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

// 8726724 = Clearwater Beach (Gulf primary, ~20mi N of PAG). The previous
// station 8726520 (St Petersburg) is on Tampa Bay — bay tides lag the
// open Gulf by ~30-90min through Egmont Key inlet, which gave wrong
// next-event times for a Gulf-facing spot. Future: derive PAG-specific
// offsets from a subordinate station once spots/<spot>.json supports it.
const tide_station = "8726724"

// Pass-a-Grille (decimal degrees). Hardcoded until spot configs land.
const pag_lat = 27.685

const pag_lon = -82.738

const data_path = "public/data/latest.json"

const index_template_path = "public/index.template.html"

const index_output_path = "public/index.html"

pub fn main() -> Nil {
  io.println("dawnpass · the watch is up")

  let buoy_opt = log_buoy(ndbc.fetch_buoy(buoy_station))
  let tide_opt = log_tide(noaa_tides.fetch_tide(tide_station))
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
  let wave_layers = wave_spec.compute_layers(buoy_opt, marine_opt)
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
    Error(e) ->
      io.println("index write failed: " <> string.inspect(e))
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
