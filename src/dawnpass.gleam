import dawnpass/ingest
import dawnpass/sources/ndbc
import dawnpass/sources/noaa_tides
import gleam/io
import gleam/json
import gleam/list
import gleam/string

const buoy_station = "42036"

const tide_station = "8726520"

const data_path = "public/data/latest.json"

pub fn main() -> Nil {
  io.println("dawnpass · the watch is up")

  let buoy_block = case ndbc.fetch_buoy(buoy_station) {
    Ok(r) -> {
      io.println("buoy " <> r.station <> " · " <> r.observed_at_utc)
      io.println(string.inspect(r))
      [#("buoy_" <> r.station, ndbc.encode(r))]
    }
    Error(e) -> {
      io.println("ndbc fetch failed: " <> string.inspect(e))
      []
    }
  }

  let tide_block = case noaa_tides.fetch_tide(tide_station) {
    Ok(r) -> {
      io.println("tide " <> r.station <> " · " <> r.observed_at_utc)
      io.println(string.inspect(r))
      [#("tide_" <> r.station, noaa_tides.encode(r))]
    }
    Error(e) -> {
      io.println("noaa fetch failed: " <> string.inspect(e))
      []
    }
  }

  let blocks: List(#(String, json.Json)) = list.append(buoy_block, tide_block)

  case ingest.write_latest(blocks, to: data_path) {
    Ok(_) -> io.println("wrote " <> data_path)
    Error(e) -> io.println("write failed: " <> string.inspect(e))
  }
}
