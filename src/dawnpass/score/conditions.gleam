//// Conditions snapshot — the input to the scoring engine.
////
//// A single moment's worth of oceanographic state, sourced from whatever
//// combination of buoy / tide / marine / wind data is available. The
//// scoring engine consumes Conditions values — never raw JSON or
//// source-specific records. Construction lives in the orchestrator
//// (dawnpass.gleam) which knows about all sources.
////
//// All fields are Option because any source can fail or be silent. The
//// scoring engine handles missing fields by treating their sub-score
//// as 0 (no contribution to the weighted sum) but does NOT veto unless
//// a factor is explicitly required.

import gleam/option.{type Option}

pub type Conditions {
  Conditions(
    /// Timestamp this snapshot represents (ISO 8601 UTC).
    at_utc: String,
    /// Significant wave height (metres).
    hs_m: Option(Float),
    /// Dominant wave period (seconds).
    tp_s: Option(Float),
    /// Bearing the swell is coming FROM (degrees true, compass).
    swell_dir_deg: Option(Int),
    /// Wind speed (knots — converted by the orchestrator from m/s).
    wind_kt: Option(Float),
    /// Bearing the wind is coming FROM (degrees true, compass).
    wind_dir_deg: Option(Int),
    /// Tide height (feet, MLLW).
    tide_ft: Option(Float),
    /// Tide phase derived from trend + closeness to next event.
    /// Not yet used by the scoring engine in v1; surfaced for future use.
    tide_phase: Option(TidePhase),
  )
}

pub type TidePhase {
  Rising
  Falling
  /// Within ~30 min of a high-tide event.
  HighSlack
  /// Within ~30 min of a low-tide event.
  LowSlack
}
