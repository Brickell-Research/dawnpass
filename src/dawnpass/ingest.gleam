//// Cross-source orchestration.
////
//// Source modules (sources/ndbc.gleam, sources/noaa_tides.gleam, etc.)
//// own their own HTTP, parsing, and per-source encoding. ingest.gleam
//// just persists a list of pre-encoded JSON blocks to disk under
//// stable per-source keys for the static site to fetch.

import filepath
import gleam/json
import gleam/result
import simplifile

pub type IngestError {
  WriteError(simplifile.FileError)
}

/// Write a list of `(key, encoded_json)` blocks as a single JSON object
/// at the given path. Creates intermediate directories if needed.
pub fn write_latest(
  blocks: List(#(String, json.Json)),
  to path: String,
) -> Result(Nil, IngestError) {
  let body = json.object(blocks) |> json.to_string

  use _ <- result.try(
    simplifile.create_directory_all(filepath.directory_name(path))
    |> result.map_error(WriteError),
  )

  simplifile.write(to: path, contents: body)
  |> result.map_error(WriteError)
}
