//// Cross-source orchestration.
////
//// Owns the file-write side and the JSON aggregation pattern. Source
//// modules (sources/ndbc.gleam, future sources/noaa_tides.gleam, etc.)
//// own their own HTTP, parsing, and per-source encoding. ingest.gleam
//// stitches results together and persists them to disk for the static
//// site to fetch.

import dawnpass/sources/ndbc.{type BuoyReading}
import filepath
import gleam/json
import gleam/result
import gleam/string
import simplifile

pub type IngestError {
  WriteError(String)
}

/// Write a buoy reading to disk as JSON.
/// Creates intermediate directories if needed.
pub fn write_latest(
  reading: BuoyReading,
  to path: String,
) -> Result(Nil, IngestError) {
  let body =
    json.object([#("buoy_" <> reading.station, ndbc.encode(reading))])
    |> json.to_string

  use _ <- result.try(
    simplifile.create_directory_all(filepath.directory_name(path))
    |> result.map_error(fn(e) { WriteError(string.inspect(e)) }),
  )

  simplifile.write(to: path, contents: body)
  |> result.map_error(fn(e) { WriteError(string.inspect(e)) })
}
