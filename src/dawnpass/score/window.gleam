//// Window detection — find rideable surf windows in a scored time series.
////
//// Hysteresis-based: a window OPENS when n_open consecutive hours have
//// score >= t_high; it CLOSES when n_close consecutive hours have
//// score < t_low. Windows shorter than l_min_hours are dropped. The
//// two-threshold scheme (t_high > t_low) prevents flapping at the
//// boundary; matches the standard signal-processing Schmitt trigger.
////
//// Empty windows list is a first-class state — for PAG it is the
//// honest answer most days, and that is the *point*. Don't synthesise
//// fake windows to avoid empty UI.

import dawnpass/score/score.{type Score, Score}
import dawnpass/score/spot_config.{type WindowConfig}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type ScoredHour {
  ScoredHour(at_utc: String, score: Score)
}

pub type Window {
  Window(
    starts_at: String,
    ends_at: String,
    length_hours: Int,
    peak_score: Float,
    peak_at: String,
    mean_score: Float,
    /// peak * 0.6 + mean * 0.4 — used to rank windows when multiple exist.
    composite: Float,
    /// Hours from `now_iso` to `starts_at`. 0 if window includes now.
    horizon_hours_out: Int,
    /// "high" (<24h), "medium" (24-48h), "low" (>48h). Not a probability.
    confidence: String,
  )
}

pub fn detect(
  hours: List(ScoredHour),
  cfg: WindowConfig,
  now_iso: String,
) -> List(Window) {
  collect_runs(hours, cfg.t_low, [], [])
  |> list.filter_map(fn(run) {
    case has_open_stretch(run, cfg.t_high, cfg.n_open) {
      True ->
        case run {
          [] -> Error(Nil)
          _ -> Ok(window_from_run(run))
        }
      False -> Error(Nil)
    }
  })
  |> list.filter(fn(w) { w.length_hours >= cfg.l_min_hours })
  |> list.map(fn(w) { with_horizon(w, now_iso) })
  |> list.sort(fn(a, b) { float.compare(b.composite, a.composite) })
}

// === Run collection ===
//
// Walk hours left-to-right. Anything score >= t_low extends the current
// run; anything below ends it (and the run is finalised into the output
// list). Empty runs are dropped silently.

fn collect_runs(
  hours: List(ScoredHour),
  t_low: Float,
  current: List(ScoredHour),
  acc: List(List(ScoredHour)),
) -> List(List(ScoredHour)) {
  case hours {
    [] ->
      case current {
        [] -> list.reverse(acc)
        _ -> list.reverse([list.reverse(current), ..acc])
      }
    [h, ..rest] ->
      case h.score.overall >=. t_low {
        True -> collect_runs(rest, t_low, [h, ..current], acc)
        False ->
          case current {
            [] -> collect_runs(rest, t_low, [], acc)
            _ -> collect_runs(rest, t_low, [], [list.reverse(current), ..acc])
          }
      }
  }
}

fn has_open_stretch(run: List(ScoredHour), t_high: Float, n: Int) -> Bool {
  count_max_consecutive(run, t_high, 0, 0) >= n
}

fn count_max_consecutive(
  run: List(ScoredHour),
  t_high: Float,
  current: Int,
  best: Int,
) -> Int {
  case run {
    [] -> int.max(current, best)
    [h, ..rest] ->
      case h.score.overall >=. t_high {
        True -> count_max_consecutive(rest, t_high, current + 1, best)
        False -> count_max_consecutive(rest, t_high, 0, int.max(current, best))
      }
  }
}

fn window_from_run(run: List(ScoredHour)) -> Window {
  let scores = list.map(run, fn(h) { h.score.overall })
  let peak =
    list.fold(scores, 0.0, fn(acc, s) {
      case s >. acc {
        True -> s
        False -> acc
      }
    })
  let total = list.fold(scores, 0.0, fn(acc, s) { acc +. s })
  let count = list.length(run)
  let mean = case count {
    0 -> 0.0
    _ -> total /. int.to_float(count)
  }
  let peak_at =
    list.find(run, fn(h) { h.score.overall == peak })
    |> result.unwrap(or: ScoredHour("", default_score()))
  let starts = case run {
    [first, ..] -> first.at_utc
    [] -> ""
  }
  let ends = case list.last(run) {
    Ok(last) -> last.at_utc
    Error(_) -> ""
  }

  Window(
    starts_at: starts,
    ends_at: ends,
    length_hours: count,
    peak_score: peak,
    peak_at: peak_at.at_utc,
    mean_score: mean,
    composite: peak *. 0.6 +. mean *. 0.4,
    horizon_hours_out: 0,
    confidence: "",
  )
}

fn default_score() -> Score {
  Score(overall: 0.0, rideable: False, sub_scores: [], vetoes: [], verdict: "")
}

fn with_horizon(w: Window, now_iso: String) -> Window {
  let hours = case minutes_until(now_iso, w.starts_at) {
    n if n < 0 -> 0
    n -> n / 60
  }
  let confidence = case hours {
    h if h < 24 -> "high"
    h if h < 48 -> "medium"
    _ -> "low"
  }
  Window(..w, horizon_hours_out: hours, confidence:)
}

fn minutes_until(now_iso: String, then_iso: String) -> Int {
  case to_minutes(now_iso), to_minutes(then_iso) {
    Ok(a), Ok(b) -> b - a
    _, _ -> 0
  }
}

fn to_minutes(iso: String) -> Result(Int, Nil) {
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

/// Highest-composite window whose horizon_hours_out is within 24h.
pub fn best_today(windows: List(Window)) -> Option(Window) {
  case list.find(windows, fn(w) { w.horizon_hours_out < 24 }) {
    Ok(w) -> Some(w)
    Error(_) -> None
  }
}

/// Highest-composite window across the whole horizon (windows is
/// pre-sorted by composite desc by `detect`).
pub fn best_overall(windows: List(Window)) -> Option(Window) {
  case windows {
    [first, ..] -> Some(first)
    [] -> None
  }
}
