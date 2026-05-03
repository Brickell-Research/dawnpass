import dawnpass/ingest
import dawnpass/sources/ndbc
import gleam/io
import gleam/string

const buoy_station = "42036"

const data_path = "public/data/latest.json"

pub fn main() -> Nil {
  io.println("dawnpass · the watch is up")

  case ndbc.fetch_buoy(buoy_station) {
    Error(e) -> io.println("ndbc fetch failed: " <> string.inspect(e))
    Ok(reading) -> {
      io.println("buoy " <> reading.station <> " · " <> reading.observed_at_utc)
      io.println(string.inspect(reading))

      case ingest.write_latest(reading, to: data_path) {
        Error(e) -> io.println("write failed: " <> string.inspect(e))
        Ok(_) -> io.println("wrote " <> data_path)
      }
    }
  }
}
