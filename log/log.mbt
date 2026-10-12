///|
/// A structured logger that writes every entry as one JSON object on one line,
/// such as
/// `{"time":"2026-10-12T14:30:05.123Z","level":"info","msg":"listening","port":8080}`.
///
/// Each entry has the time (RFC 3339, UTC, milliseconds), the level (`info`,
/// `warn` or `error`), the message, and then its structured fields.
///
/// The logger does no I/O itself: it hands each line to `write_line` and asks
/// `now` for the time, so the caller decides where lines go and which clock
/// they carry.
pub struct Logger {
  priv write_line : (String) -> Unit
  priv now : () -> Int64
}

///|
/// Creates a logger.
///
/// - `write_line` receives each entry as one line of JSON, without the
///   trailing newline.
/// - `now` returns the current time in milliseconds since the Unix epoch.
pub fn Logger::Logger(
  write_line~ : (String) -> Unit,
  now~ : () -> Int64,
) -> Logger {
  { write_line, now, }
}

///|
/// Writes an entry at level `info`. `fields` follow the message as
/// top-level keys of the entry, in the order given. A field named `time`,
/// `level` or `msg` is written as `fields.time`, `fields.level` or
/// `fields.msg`, so it never replaces the entry's own.
pub fn Logger::info(
  self : Logger,
  msg : String,
  fields? : Map[String, Json] = {},
) -> Unit {
  self.write("info", msg, fields)
}

///|
/// Writes an entry at level `warn`. `fields` are as for `info`.
pub fn Logger::warn(
  self : Logger,
  msg : String,
  fields? : Map[String, Json] = {},
) -> Unit {
  self.write("warn", msg, fields)
}

///|
/// Writes an entry at level `error`. `fields` are as for `info`.
pub fn Logger::error(
  self : Logger,
  msg : String,
  fields? : Map[String, Json] = {},
) -> Unit {
  self.write("error", msg, fields)
}

///|
fn Logger::write(
  self : Logger,
  level : String,
  msg : String,
  fields : Map[String, Json],
) -> Unit {
  let entry : Map[String, Json] = {
    "time": Json::string(format_time((self.now)())),
    "level": Json::string(level),
    "msg": Json::string(msg),
  }
  for key, value in fields {
    // A field never replaces the entry's own keys; it moves aside instead.
    let key = if key is ("time" | "level" | "msg") {
      "fields.\{key}"
    } else {
      key
    }
    entry[key] = value
  }
  (self.write_line)(Json::object(entry).stringify())
}

///|
/// Formats milliseconds since the Unix epoch as an RFC 3339 UTC timestamp
/// with milliseconds, such as `2026-10-12T14:30:05.123Z`.
fn format_time(ms : Int64) -> String {
  let ms_per_day = 86_400_000L
  let days = floor_div(ms, ms_per_day)
  let ms_of_day = ms - days * ms_per_day
  // Civil date from a day count, after Howard Hinnant's `civil_from_days`.
  let z = days + 719_468L
  let era = floor_div(z, 146_097L)
  let doe = z - era * 146_097L
  let yoe = (doe - doe / 1460L + doe / 36_524L - doe / 146_096L) / 365L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let day = doy - (153L * mp + 2L) / 5L + 1L
  let month = if mp < 10L { mp + 3L } else { mp - 9L }
  let year = yoe + era * 400L + (if month <= 2L { 1L } else { 0L })
  let hour = ms_of_day / 3_600_000L
  let minute = ms_of_day / 60_000L % 60L
  let second = ms_of_day / 1000L % 60L
  let milli = ms_of_day % 1000L
  "\{pad(year, 4)}-\{pad(month, 2)}-\{pad(day, 2)}T\{pad(hour, 2)}:\{pad(minute, 2)}:\{pad(second, 2)}.\{pad(milli, 3)}Z"
}

///|
fn floor_div(a : Int64, b : Int64) -> Int64 {
  let q = a / b
  if a % b != 0L && (a < 0L) != (b < 0L) {
    q - 1L
  } else {
    q
  }
}

///|
fn pad(n : Int64, width : Int) -> String {
  let digits = n.to_string()
  let out = StringBuilder()
  for _ in digits.length()..<width {
    out.write_char('0')
  }
  out.write_string(digits)
  out.to_string()
}
