//// Inline spot configurations.
////
//// In v1 each spot is a Gleam constant. Numbers come from the research
//// agents' findings:
////   - Longboard science (Hs floor 0.3m, sweet 0.5-1.2m, ceiling ~2m;
////     Tp floor 5s, sweet 7-11s; ±50° swell-direction window;
////     onshore wind > ~12kt is a hard veto regardless of swell).
////   - PAG-specific reality (Gulf microtidal, sea breeze kills morning
////     window ~2pm; W/SW swell preferred, true W/NW for cold-front days).
////
//// Tide is intentionally NOT scored in v1 — surfaced on the page but
//// not weighted into the score. Layered in once we have observed-vs-
//// rated session data to calibrate against.

import dawnpass/score/spot_config.{Factor, SpotConfig, Verdict, WindowConfig}

pub const pag = SpotConfig(
  name: "Pass-a-Grille",
  beach_normal_deg: 270,
  factors: [
    Factor(
      name: "hs_m",
      // Wave height in metres. Floor below 0.3m, sweet 0.5-1.2m, longboard
      // becomes wrong tool above ~2m. Veto at sub-score 0 catches sub-floor.
      breakpoints: [
        #(0.0, 0.0),
        #(0.3, 0.0),
        #(0.5, 0.4),
        #(0.8, 0.8),
        #(1.2, 1.0),
        #(1.8, 0.7),
        #(2.5, 0.3),
      ],
      weight: 1.0,
      veto_below_subscore: 0.001,
      veto_message: "wave height too small for longboard",
    ),
    Factor(
      name: "tp_s",
      // Period in seconds. Below 5s = wind chop. 7-11s sweet. Above 14s
      // tapers because at small Hs long period jacks too steep.
      breakpoints: [
        #(0.0, 0.0),
        #(4.0, 0.0),
        #(5.0, 0.3),
        #(7.0, 0.8),
        #(9.0, 1.0),
        #(12.0, 1.0),
        #(14.0, 0.7),
        #(20.0, 0.5),
      ],
      weight: 0.8,
      veto_below_subscore: 0.001,
      veto_message: "period too short, no organisation",
    ),
    Factor(
      name: "swell_dir_offset",
      // Absolute degrees off the beach normal (270° at PAG). 0 = swell
      // straight on the beach (best). >50° starts shadowing/wrapping.
      breakpoints: [
        #(0.0, 1.0),
        #(20.0, 0.95),
        #(40.0, 0.8),
        #(60.0, 0.5),
        #(90.0, 0.2),
        #(120.0, 0.0),
      ],
      weight: 0.6,
      veto_below_subscore: 0.0,
      veto_message: "",
    ),
    Factor(
      name: "wind_kt_signed",
      // Signed wind on the offshore axis. Positive = offshore, negative =
      // onshore. Veto at ≤ -12 kt (strong onshore = hard kill regardless
      // of swell — the universal veto from the longboard-science agent).
      breakpoints: [
        #(-30.0, 0.0),
        #(-12.0, 0.0),
        #(-8.0, 0.3),
        #(-4.0, 0.6),
        #(0.0, 0.85),
        #(5.0, 1.0),
        #(10.0, 1.0),
        #(15.0, 0.7),
        #(20.0, 0.4),
        #(30.0, 0.1),
      ],
      weight: 1.2,
      veto_below_subscore: 0.001,
      veto_message: "onshore wind too strong (>12 kt)",
    ),
  ],
  verdicts: [
    Verdict(min_score: 0.0, label: "skip"),
    Verdict(min_score: 3.0, label: "marginal"),
    Verdict(min_score: 5.0, label: "fun-sized"),
    Verdict(min_score: 7.0, label: "go now"),
    Verdict(min_score: 9.0, label: "fires"),
  ],
  windows: WindowConfig(
    t_high: 6.0,
    t_low: 5.0,
    n_open: 2,
    n_close: 1,
    l_min_hours: 2,
  ),
)
