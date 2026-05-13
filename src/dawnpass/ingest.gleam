//// Cross-source orchestration.
////
//// Source modules (sources/ndbc.gleam, sources/noaa_tides.gleam, etc.)
//// own their own HTTP, parsing, and per-source encoding. ingest.gleam
//// just persists a list of pre-encoded JSON blocks to disk under
//// stable per-source keys for the static site to fetch.
////
//// Also responsible for SSR'ing the wave-layer paths into index.html so
//// no-JS / first-paint visitors see the correct wave shape immediately.

import dawnpass/wave_spec.{type WaveLayers}
import filepath
import gleam/json
import gleam/result
import gleam/string
import simplifile

pub type IngestError {
  WriteError(simplifile.FileError)
  ReadError(simplifile.FileError)
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

/// Write any pre-encoded JSON value to disk. Creates intermediate
/// directories. Used for derived static endpoints like
/// `public/api/today.json` whose top-level shape is not a `(key, value)`
/// blocks map.
pub fn write_json(
  value: json.Json,
  to path: String,
) -> Result(Nil, IngestError) {
  let body = json.to_string(value)

  use _ <- result.try(
    simplifile.create_directory_all(filepath.directory_name(path))
    |> result.map_error(WriteError),
  )

  simplifile.write(to: path, contents: body)
  |> result.map_error(WriteError)
}

/// Render the three wave-layer SVG paths at phase=0 and substitute them
/// into the index template, producing the deployed index.html.
///
/// Placeholders:  {{WAVE_CHOP_D}}  {{WAVE_MEAN_D}}  {{WAVE_SWELL_D}}  {{SITE_VERSION}}
///
/// Byte-equivalence with public/wave.js drawLayer is enforced by snapshot
/// tests against captured JS fixtures (test/wave_spec_test.gleam).
pub fn write_index(
  layers: WaveLayers,
  version version: String,
  template template_path: String,
  output output_path: String,
) -> Result(Nil, IngestError) {
  use template <- result.try(
    simplifile.read(template_path)
    |> result.map_error(ReadError),
  )

  let chop_d = wave_spec.render_path(layers.chop, 0.0)
  let mean_d = wave_spec.render_path(layers.mean, 0.0)
  let swell_d = wave_spec.render_path(layers.swell, 0.0)

  let body =
    template
    |> string.replace(each: "{{WAVE_CHOP_D}}", with: chop_d)
    |> string.replace(each: "{{WAVE_MEAN_D}}", with: mean_d)
    |> string.replace(each: "{{WAVE_SWELL_D}}", with: swell_d)
    |> string.replace(each: "{{SITE_VERSION}}", with: version)

  simplifile.write(to: output_path, contents: body)
  |> result.map_error(WriteError)
}
