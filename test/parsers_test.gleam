//// Snapshot tests for the source parsers.
////
//// Each test reads a frozen fixture from test/fixtures/, runs it
//// through the relevant parser, and snaps the encoded JSON via birdie.
//// Fixtures are real responses captured once; they don't refresh.
////
//// Workflow when a parser changes:
////   1. `gleam test` writes a `.new` snapshot if output diverges.
////   2. `gleam run -m birdie` to review and accept/reject diffs.

import birdie
import dawnpass/sources/ndbc
import dawnpass/sources/noaa_tides
import dawnpass/sources/open_meteo_marine
import gleam/json
import gleam/list
import gleam/string
import simplifile

fn read_fixture(name: String) -> String {
  let assert Ok(body) = simplifile.read("test/fixtures/" <> name)
  body
}

pub fn ndbc_42036_parse_test() {
  let assert Ok(reading) =
    ndbc.parse_realtime2_body("42036", read_fixture("ndbc_42036.txt"))
  reading
  |> ndbc.encode
  |> json.to_string
  |> birdie.snap(title: "ndbc 42036 latest reading")
}

pub fn noaa_water_level_parse_test() {
  let assert Ok(level) =
    noaa_tides.parse_water_level(read_fixture("noaa_water_level_8726520.json"))
  string.inspect(level)
  |> birdie.snap(title: "noaa water_level 8726520")
}

pub fn noaa_hilo_parse_test() {
  let assert Ok(events) =
    noaa_tides.parse_hilo(read_fixture("noaa_hilo_8726520.json"))
  events
  |> list.map(string.inspect)
  |> string.join("\n")
  |> birdie.snap(title: "noaa hilo 8726520")
}

pub fn open_meteo_marine_parse_test() {
  let assert Ok(reading) =
    open_meteo_marine.parse_marine(read_fixture("open_meteo_marine_pag.json"))
  reading
  |> open_meteo_marine.encode
  |> json.to_string
  |> birdie.snap(title: "open-meteo marine pag")
}
