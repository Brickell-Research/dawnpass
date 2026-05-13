//// Terse "now" digest for the primary spot — published as a static file
//// at `public/api/today.json` so downstream consumers (Obsidian daily
//// note, Slack bots, watch face complications) can fetch a compact JSON
//// shape without parsing the full `latest.json` history payload.
////
//// Verdict / overall / rideable come from the existing scoring engine
//// (`score/orchestrator.gleam`). Wave height is converted to feet at the
//// boundary so consumers don't need their own unit table.
////
//// Pure: takes pre-fetched source readings, returns a `json.Json`. No HTTP,
//// no I/O — the orchestrator in `dawnpass.gleam` writes the file.

import dawnpass/score/orchestrator
import dawnpass/score/score
import dawnpass/score/spot_config.{type SpotConfig}
import dawnpass/sources/ndbc.{type BuoyReading}
import dawnpass/sources/noaa_tides.{
  type TideEvent, type TideReading, Falling, High, Low, Rising, Slack,
}
import dawnpass/sources/open_meteo_forecast.{type WindForecast}
import dawnpass/sources/open_meteo_marine.{type MarineReading}
import gleam/json
import gleam/option.{type Option, None, Some}

// 1 metre = 3.28084 feet. Same convention dawnpass uses elsewhere.
const m_per_ft: Float = 3.280839895

/// Build the `today.json` payload for a single spot. Re-uses the scoring
/// engine for verdict/overall/rideable so this stays one source of truth.
pub fn build_today(
  slug slug: String,
  name name: String,
  latitude latitude: Float,
  longitude longitude: Float,
  buoy buoy: Option(BuoyReading),
  tide tide: Option(TideReading),
  marine marine: Option(MarineReading),
  wind wind: Option(WindForecast),
  spot spot: SpotConfig,
) -> json.Json {
  let now_iso = orchestrator.pick_now_iso(buoy, tide, marine)
  let conditions =
    orchestrator.build_now_conditions(now_iso, buoy, tide, marine, wind)
  let now_score = score.score(conditions, spot)

  let wave_ft = case conditions.hs_m {
    Some(m) -> Some(m *. m_per_ft)
    None -> None
  }

  json.object([
    #("generated_at_utc", json.string(now_iso)),
    #(
      "spot",
      json.object([
        #("slug", json.string(slug)),
        #("name", json.string(name)),
        #("latitude", json.float(latitude)),
        #("longitude", json.float(longitude)),
      ]),
    ),
    #("wave_ft", encode_optional(wave_ft, json.float)),
    #("period_s", encode_optional(conditions.tp_s, json.float)),
    #("wind_kt", encode_optional(conditions.wind_kt, json.float)),
    #("wind_dir_deg", encode_optional(conditions.wind_dir_deg, json.int)),
    #("tide", encode_tide_summary(tide)),
    #(
      "score",
      json.object([
        #("overall", json.float(now_score.overall)),
        #("rideable", json.bool(now_score.rideable)),
        #("verdict", json.string(now_score.verdict)),
      ]),
    ),
  ])
}

// === Tide summary ===
//
// Subset of TideReading sized for at-a-glance consumers: height, trend,
// the very next hi/lo. The full `upcoming` list lives in latest.json and
// has no business in a one-line surf line.

fn encode_tide_summary(t: Option(TideReading)) -> json.Json {
  case t {
    None -> json.null()
    Some(r) ->
      json.object([
        #("height_ft", json.float(r.height_ft)),
        #("trend", json.string(trend_to_string(r.trend))),
        #("next_event", encode_event_summary(r.next_event)),
      ])
  }
}

fn trend_to_string(t: noaa_tides.Trend) -> String {
  case t {
    Rising -> "rising"
    Falling -> "falling"
    Slack -> "slack"
  }
}

fn encode_event_summary(e: TideEvent) -> json.Json {
  let kind_str = case e.kind {
    High -> "high"
    Low -> "low"
  }
  json.object([
    #("kind", json.string(kind_str)),
    #("at_utc", json.string(e.at_utc)),
    #("height_ft", json.float(e.height_ft)),
  ])
}

fn encode_optional(o: Option(a), encode: fn(a) -> json.Json) -> json.Json {
  case o {
    None -> json.null()
    Some(v) -> encode(v)
  }
}
