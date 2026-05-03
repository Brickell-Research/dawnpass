//// Spot config — per-spot thresholds and rules consumed by score.gleam.
////
//// In v1 each spot is defined as an inline Gleam constant in spots.gleam.
//// JSON loading is deferred until the calibration loop arrives (where
//// session feedback will tune weights and breakpoints, and config-as-data
//// becomes an architectural requirement).
////
//// The shape mirrors the Magicseaweed / KSL Surfability convention:
////   - per-factor sub-scores via piecewise-linear breakpoint tables
////   - weighted-sum aggregation
////   - per-factor veto (any single sub-score below threshold = unrideable)
////   - score → verdict label table for human-readable output

pub type SpotConfig {
  SpotConfig(
    name: String,
    /// Bearing the beach faces (perpendicular pointing OUT to open water).
    /// PAG faces west = 270°. Used to compute swell-direction offset and
    /// wind onshore/offshore axis.
    beach_normal_deg: Int,
    factors: List(Factor),
    /// Score → label bands, sorted by min_score ascending. The verdict for
    /// a given score is the label of the highest band whose min_score
    /// the score meets. Empty list = no verdict in output.
    verdicts: List(Verdict),
    windows: WindowConfig,
  )
}

pub type Factor {
  Factor(
    /// Logical name the score function dispatches on.
    /// Recognised: "hs_m", "tp_s", "swell_dir_offset", "wind_kt_signed".
    name: String,
    /// Piecewise-linear (input_value, sub_score 0..1) mapping. Values
    /// outside the range are clamped to the endpoint sub_score.
    breakpoints: List(#(Float, Float)),
    /// Contribution to the weighted sum.
    weight: Float,
    /// Sub-score below this threshold triggers a hard veto on the spot.
    /// Use 0.0 to disable veto for this factor.
    veto_below_subscore: Float,
    /// Human-readable reason emitted when this veto fires.
    veto_message: String,
  )
}

pub type Verdict {
  Verdict(min_score: Float, label: String)
}

pub type WindowConfig {
  WindowConfig(
    /// Open a window when N consecutive scored hours are >= t_high.
    t_high: Float,
    /// Close it when N consecutive hours drop below t_low.
    t_low: Float,
    /// Hours above t_high required to open.
    n_open: Int,
    /// Hours below t_low required to close.
    n_close: Int,
    /// Minimum window length kept; shorter ones are dropped.
    l_min_hours: Int,
  )
}
