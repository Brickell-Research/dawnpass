import dawnpass/ingest
import dawnpass/score/orchestrator as score_orch
import dawnpass/score/spot_config.{type SpotConfig}
import dawnpass/score/spots
import dawnpass/sources/ndbc
import dawnpass/sources/noaa_tides
import dawnpass/sources/open_meteo_forecast
import dawnpass/sources/open_meteo_marine
import dawnpass/wave_spec
import envoy
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const buoy_station = "42036"

// Pass-a-Grille (decimal degrees).
const pag_lat = 27.685

const pag_lon = -82.738

// Venice South Jetty (decimal degrees). Same offshore swell region as PAG
// but ~85min south by car; the rock jetty produces a meaningfully different
// wave shape on the same model inputs. Shares NDBC 42036 (regional buoy);
// has its own NOAA tide stations because Venice tides phase ~30-60min off
// Clearwater Beach.
const venice_lat = 27.073

const venice_lon = -82.456

/// One surf spot's identity for the per-spot ingest loop. `slug` is the
/// short JSON key (e.g. "pag", "venice_south") under which this spot's
/// blocks land in latest.json. `spot_config` is the scoring config (factor
/// breakpoints, verdicts, windows) from src/dawnpass/score/spots.gleam.
/// `tide_stations` is the per-spot fallback chain — each spot's tide is
/// fetched independently because Gulf-coast tides phase by tens of minutes
/// across even ~50mi of latitude.
pub type Spot {
  Spot(
    slug: String,
    name: String,
    latitude: Float,
    longitude: Float,
    spot_config: SpotConfig,
    tide_stations: List(String),
  )
}

const pag_spot = Spot(
  slug: "pag",
  name: "Pass-a-Grille",
  latitude: pag_lat,
  longitude: pag_lon,
  spot_config: spots.pag,
  // 8726347 (Pass-a-Grille Beach, FL) — primary; subordinate harmonic-only
  //   station literally at the spot (sensor decommissioned 1991, harmonic
  //   predictions still publish). Routes through fetch_tide_predictions_only
  //   because water_level returns "no data" for subordinate stations.
  //   Matches Surfline's PAG tide source.
  // 8726724 (Clearwater Beach) — fallback; Gulf-facing primary with a live
  //   gauge, ~20mi N. Leads PAG by ~50min and runs ~0.5ft taller, so the
  //   fallback is degraded but better than nothing.
  tide_stations: ["8726347", "8726724"],
)

const venice_spot = Spot(
  slug: "venice_south",
  name: "Venice South Jetty",
  latitude: venice_lat,
  longitude: venice_lon,
  spot_config: spots.venice_south,
  // 8725889 (Venice Inlet, inside) — sits at Casey Pass mouth, ~50yds from
  //   the south jetty rocks. Subordinate to 8726520 in NOAA's harmonic
  //   reference but the predictions are Venice-specific.
  // 8726034 (Siesta Key, Big Sarasota Pass) — Gulf-facing inlet ~12mi N
  //   with its own harmonic data; covers Venice if 8725889 is in maintenance.
  tide_stations: ["8725889", "8726034"],
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

  // Shared source: NDBC buoy carries regional swell signal that's identical
  // for any spot in the eastern Gulf within ~100mi. Fetched once.
  let buoy_opt = log_buoy(ndbc.fetch_buoy(buoy_station))

  // Per-spot fan-out: each spot fetches its own tide + marine + wind at its
  // lat/lon and computes its own wave layers + score. Output lands under
  // spots.<slug>. Tide moved per-spot because Gulf-coast phase shifts
  // matter at the timing precision the next-event line needs.
  let spot_entries =
    list.map(spots_list, fn(s) { build_spot_entry(s, buoy_opt) })

  let buoy_block = case buoy_opt {
    Some(r) -> [#("buoy_" <> r.station, ndbc.encode(r))]
    None -> []
  }

  let spots_pairs =
    list.map(spot_entries, fn(e) {
      let SpotEntry(slug:, json:, ..) = e
      #(slug, json)
    })
  let spots_block = [#("spots", json.object(spots_pairs))]

  let blocks: List(#(String, json.Json)) =
    list.flatten([buoy_block, spots_block])

  case ingest.write_latest(blocks, to: data_path) {
    Ok(_) -> io.println("wrote " <> data_path)
    Error(e) -> io.println("write failed: " <> string.inspect(e))
  }

  // SSR the wave-layer paths into index.html so first paint is correct
  // without JS. JS still mounts on top to animate. The template only
  // substitutes one set of {{WAVE_*_D}} placeholders, so the SSR uses
  // PAG's wave layers as canonical (PAG is the first spot in spots_list
  // and the daily-ritual primary). Venice's wave SVG paints from JS at
  // render time once data.spots.venice_south.wave lands.
  let canonical_wave = canonical_wave_layers(spot_entries, buoy_opt)
  // SITE_VERSION is the date of the last non-`refresh:` commit, computed
  // by the workflows that invoke `gleam run`. Locally (no env var) it
  // shows "dev" so a deployed footer can never be confused with a sandbox
  // rebuild.
  let site_version = result.unwrap(envoy.get("SITE_VERSION"), "dev")
  case
    ingest.write_index(
      canonical_wave,
      version: site_version,
      template: index_template_path,
      output: index_output_path,
    )
  {
    Ok(_) -> io.println("wrote " <> index_output_path)
    Error(e) -> io.println("index write failed: " <> string.inspect(e))
  }
}

/// Container for one spot's per-fetch state plus the encoded JSON object
/// that lands under `spots.<slug>` and the computed WaveLayers (kept around
/// so PAG's layers can drive the SSR substitution).
type SpotEntry {
  SpotEntry(slug: String, json: json.Json, wave_layers: wave_spec.WaveLayers)
}

fn build_spot_entry(
  spot: Spot,
  buoy_opt: Option(ndbc.BuoyReading),
) -> SpotEntry {
  let tide_opt =
    log_tide(noaa_tides.fetch_tide_with_fallback(spot.tide_stations), spot.slug)
  let marine_opt =
    log_marine(
      open_meteo_marine.fetch_marine(
        latitude: spot.latitude,
        longitude: spot.longitude,
      ),
      spot.slug,
    )
  let wind_opt =
    log_wind(
      open_meteo_forecast.fetch_wind(
        latitude: spot.latitude,
        longitude: spot.longitude,
      ),
      spot.slug,
    )

  let wave_layers = wave_spec.compute_layers(buoy_opt, marine_opt, wind_opt)
  let spot_json =
    encode_spot_block(spot, buoy_opt, tide_opt, marine_opt, wind_opt)

  SpotEntry(slug: spot.slug, json: spot_json, wave_layers:)
}

/// Pure encoder: given pre-fetched source readings + a spot config, produce
/// the JSON object that lands under `spots.<slug>` in latest.json. Split
/// from `build_spot_entry` so tests can hit it with hand-built records
/// without making any HTTP calls.
pub fn encode_spot_block(
  spot: Spot,
  buoy: Option(ndbc.BuoyReading),
  tide: Option(noaa_tides.TideReading),
  marine: Option(open_meteo_marine.MarineReading),
  wind: Option(open_meteo_forecast.WindForecast),
) -> json.Json {
  let wave_layers = wave_spec.compute_layers(buoy, marine, wind)
  let score_json =
    score_orch.build_block(buoy, tide, marine, wind, spot.spot_config)

  let tide_json = case tide {
    Some(r) -> noaa_tides.encode(r)
    None -> json.null()
  }
  let marine_json = case marine {
    Some(r) -> open_meteo_marine.encode(r)
    None -> json.null()
  }
  let wind_json = case wind {
    Some(r) -> open_meteo_forecast.encode(r)
    None -> json.null()
  }

  json.object([
    #("name", json.string(spot.name)),
    #("latitude", json.float(spot.latitude)),
    #("longitude", json.float(spot.longitude)),
    #("tide", tide_json),
    #("marine", marine_json),
    #("wind", wind_json),
    #("wave", wave_spec.encode(wave_layers)),
    #("score", score_json),
  ])
}

/// SSR substitution needs a single set of WaveLayers. Use the first spot's
/// (PAG by convention). Falls back to a Silent layer set if the loop somehow
/// produced nothing — the renderer handles silent/null amplitudes already.
fn canonical_wave_layers(
  spot_entries: List(SpotEntry),
  buoy_opt: Option(ndbc.BuoyReading),
) -> wave_spec.WaveLayers {
  case spot_entries {
    [first, ..] -> first.wave_layers
    [] -> wave_spec.compute_layers(buoy_opt, None, None)
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
  slug: String,
) -> Option(noaa_tides.TideReading) {
  case res {
    Ok(r) -> {
      io.println(
        "tide " <> slug <> " · " <> r.station <> " · " <> r.observed_at_utc,
      )
      io.println(string.inspect(r))
      Some(r)
    }
    Error(e) -> {
      io.println("noaa fetch (" <> slug <> ") failed: " <> string.inspect(e))
      None
    }
  }
}

fn log_marine(
  res: Result(open_meteo_marine.MarineReading, open_meteo_marine.MarineError),
  slug: String,
) -> Option(open_meteo_marine.MarineReading) {
  case res {
    Ok(r) -> {
      io.println("marine " <> slug <> " · " <> r.observed_at_utc)
      io.println(string.inspect(r))
      Some(r)
    }
    Error(e) -> {
      io.println(
        "open-meteo marine fetch (" <> slug <> ") failed: " <> string.inspect(e),
      )
      None
    }
  }
}

fn log_wind(
  res: Result(
    open_meteo_forecast.WindForecast,
    open_meteo_forecast.ForecastError,
  ),
  slug: String,
) -> Option(open_meteo_forecast.WindForecast) {
  case res {
    Ok(r) -> {
      io.println("wind " <> slug <> " · " <> r.observed_at_utc)
      Some(r)
    }
    Error(e) -> {
      io.println(
        "open-meteo forecast (wind, "
        <> slug
        <> ") failed: "
        <> string.inspect(e),
      )
      None
    }
  }
}
