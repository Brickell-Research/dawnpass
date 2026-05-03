//// Pure scoring function — Conditions × SpotConfig → Score.
////
//// Algorithm (per Magicseaweed/KSL convention):
////   1. For each factor in the spot config:
////      a. Extract the factor's input value from Conditions (lookup by name).
////      b. Interpolate the breakpoint table → sub_score in [0, 1].
////      c. If sub_score < veto_below_subscore → record veto.
////   2. Compute overall = 10 × Σ(weight_i × sub_score_i) / Σ(weight_i).
////   3. If any veto fired → overall = 0.0, rideable = false.
////   4. Look up verdict label from the score → label table.
////
//// Missing Conditions fields → sub_score 0, no veto fires unless the
//// factor's veto threshold is itself > 0 (most factors set it to 0,
//// which means "this factor doesn't get to veto on its own").

import dawnpass/score/conditions.{type Conditions}
import dawnpass/score/spot_config.{type SpotConfig, type Verdict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

pub type Score {
  Score(
    /// 0.0 .. 10.0
    overall: Float,
    /// false if any factor's sub-score fell below its veto threshold.
    rideable: Bool,
    /// (factor name, sub_score 0..1) — preserved for debug + future
    /// calibration. Order matches spot_config.factors.
    sub_scores: List(#(String, Float)),
    /// Per-veto messages from factors that triggered. Empty if rideable.
    vetoes: List(String),
    /// Human-readable label from the spot's verdict bands.
    verdict: String,
  )
}

pub fn score(c: Conditions, spot: SpotConfig) -> Score {
  let evaluated =
    list.map(spot.factors, fn(f) {
      let value = extract_factor_value(c, f.name, spot.beach_normal_deg)
      let sub = case value {
        None -> 0.0
        Some(v) -> interpolate(f.breakpoints, v)
      }
      let veto = case sub <. f.veto_below_subscore {
        True -> [f.veto_message]
        False -> []
      }
      #(f, sub, veto)
    })

  let sub_scores =
    list.map(evaluated, fn(e) {
      let #(f, sub, _) = e
      #(f.name, sub)
    })

  let vetoes =
    list.flat_map(evaluated, fn(e) {
      let #(_, _, v) = e
      v
    })

  let total_weight =
    list.fold(spot.factors, 0.0, fn(acc, f) { acc +. f.weight })

  let weighted_sum =
    list.fold(evaluated, 0.0, fn(acc, e) {
      let #(f, sub, _) = e
      acc +. f.weight *. sub
    })

  let raw_overall = case total_weight >. 0.0 {
    True -> 10.0 *. weighted_sum /. total_weight
    False -> 0.0
  }

  let rideable = list.is_empty(vetoes)
  let overall = case rideable {
    True -> raw_overall
    False -> 0.0
  }

  Score(
    overall:,
    rideable:,
    sub_scores:,
    vetoes:,
    verdict: lookup_verdict(spot.verdicts, overall),
  )
}

// === Factor extraction ===
//
// Each recognised factor name maps a Conditions value → Option(Float)
// to be looked up in the breakpoint table. Unknown names return None
// (no contribution, no veto).

fn extract_factor_value(
  c: Conditions,
  name: String,
  beach_normal_deg: Int,
) -> Option(Float) {
  case name {
    "hs_m" -> c.hs_m
    "tp_s" -> c.tp_s
    "swell_dir_offset" ->
      option.map(c.swell_dir_deg, fn(deg) {
        int.to_float(angular_offset(deg, beach_normal_deg))
      })
    "wind_kt_signed" ->
      case c.wind_kt, c.wind_dir_deg {
        Some(speed), Some(deg) ->
          Some(signed_wind_kt(speed, deg, beach_normal_deg))
        _, _ -> None
      }
    _ -> None
  }
}

/// Absolute angular offset between a bearing and the beach normal.
/// Result in [0, 180]. e.g. swell from 270 with normal 270 → 0
/// (perfectly on); swell from 0 with normal 270 → 90 (sideshore).
pub fn angular_offset(bearing_deg: Int, normal_deg: Int) -> Int {
  let raw = bearing_deg - normal_deg
  let modded = case raw % 360 {
    n if n < 0 -> n + 360
    n -> n
  }
  case modded > 180 {
    True -> 360 - modded
    False -> modded
  }
}

/// Project the wind speed onto the offshore axis. Positive = offshore
/// (wind blowing FROM land TO sea), negative = onshore. Magnitude
/// preserved at the limits (full speed when straight on/off-shore),
/// reduced to ~0 when sideshore.
pub fn signed_wind_kt(
  speed_kt: Float,
  wind_dir_deg: Int,
  beach_normal_deg: Int,
) -> Float {
  // Offshore direction = beach_normal + 180 (wind blowing FROM that bearing).
  let offshore_dir = { beach_normal_deg + 180 } % 360
  let diff = signed_angular_diff(wind_dir_deg, offshore_dir)
  // cos(0) = 1 (full offshore), cos(±90) = 0 (sideshore), cos(180) = -1 (full onshore)
  let radians = int.to_float(diff) *. pi() /. 180.0
  speed_kt *. cosine(radians)
}

fn signed_angular_diff(a_deg: Int, b_deg: Int) -> Int {
  let raw = { { a_deg - b_deg + 540 } % 360 } - 180
  raw
}

// === Breakpoint interpolation ===

/// Piecewise-linear interpolation between (input, output) breakpoints.
/// Outside the range of inputs, clamps to the endpoint output.
/// Empty breakpoints → 0.0.
pub fn interpolate(points: List(#(Float, Float)), x: Float) -> Float {
  case points {
    [] -> 0.0
    [#(_, y)] -> y
    [#(x0, y0), #(x1, y1), ..rest] ->
      case x <=. x0 {
        True -> y0
        False ->
          case x <=. x1 {
            True -> {
              let span = x1 -. x0
              case span == 0.0 {
                True -> y0
                False -> y0 +. { y1 -. y0 } *. { x -. x0 } /. span
              }
            }
            False -> interpolate([#(x1, y1), ..rest], x)
          }
      }
  }
}

// === Verdict lookup ===

fn lookup_verdict(verdicts: List(Verdict), score: Float) -> String {
  // Find the highest-min-score verdict whose threshold the score meets.
  let matched =
    list.filter(verdicts, fn(v) { score >=. v.min_score })
    |> list.sort(fn(a, b) { float.compare(b.min_score, a.min_score) })
  case matched {
    [v, ..] -> v.label
    [] -> ""
  }
}

// === Math helpers ===
//
// Gleam's stdlib does not expose Float.cos; we shim via the Erlang
// :math:cos/1 BIF.

@external(erlang, "math", "cos")
fn cosine(rad: Float) -> Float

fn pi() -> Float {
  3.141592653589793
}
