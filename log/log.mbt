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
/// with milliseconds, such as `2026-10-12T14:30:05.123Z`: the time format
/// of log entries, also used for times the Admin API shows.
pub fn format_time(ms : Int64) -> String {
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

///|
/// The time `text` gives as an RFC 3339 date-time, such as
/// `2026-10-12T14:30:05Z` or `2026-10-12T16:30:05.123+02:00`, in
/// milliseconds since the Unix epoch. Digits of the fraction beyond
/// milliseconds are dropped, and a leap second counts as the first second
/// of the next minute. `None` when it is not one.
pub fn parse_time(text : String) -> Int64? {
  let c = text.iter().collect()
  // The number that the `count` digits from `start` write, if they are
  // digits.
  let number = (start : Int, count : Int) => {
    if start + count > c.length() {
      return None
    }
    let mut n = 0
    for i in start..<(start + count) {
      guard c[i] >= '0' && c[i] <= '9' else { return None }
      n = n * 10 + (c[i].to_int() - '0'.to_int())
    }
    Some(n)
  }
  let at = (i : Int, chars : String) => {
    i < c.length() && chars.contains_char(c[i])
  }
  guard number(0, 4) is Some(year) &&
    at(4, "-") &&
    number(5, 2) is Some(month) &&
    at(7, "-") &&
    number(8, 2) is Some(day) &&
    at(10, "Tt") &&
    number(11, 2) is Some(hour) &&
    at(13, ":") &&
    number(14, 2) is Some(minute) &&
    at(16, ":") &&
    number(17, 2) is Some(second) else {
    return None
  }
  let mut i = 19
  let mut millisecond = 0
  if at(i, ".") {
    i += 1
    let start = i
    while i < c.length() && c[i] >= '0' && c[i] <= '9' {
      if i - start < 3 {
        millisecond = millisecond * 10 + (c[i].to_int() - '0'.to_int())
      }
      i += 1
    }
    match i - start {
      0 => return None
      1 => millisecond *= 100
      2 => millisecond *= 10
      _ => ()
    }
  }
  let offset_minutes = if at(i, "Zz") && i + 1 == c.length() {
    0
  } else if at(i, "+-") &&
    i + 6 == c.length() &&
    number(i + 1, 2) is Some(offset_hour) &&
    at(i + 3, ":") &&
    number(i + 4, 2) is Some(offset_minute) &&
    offset_hour <= 23 &&
    offset_minute <= 59 {
    let minutes = offset_hour * 60 + offset_minute
    if c[i] == '-' {
      -minutes
    } else {
      minutes
    }
  } else {
    return None
  }
  if month < 1 ||
    month > 12 ||
    day < 1 ||
    day > days_in_month(year, month) ||
    hour > 23 ||
    minute > 59 ||
    second > 60 {
    return None
  }
  let days = days_from_civil(year, month, day).to_int64()
  let seconds = ((days * 24L + hour.to_int64()) * 60L + minute.to_int64()) * 60L +
    second.to_int64() -
    offset_minutes.to_int64() * 60L
  Some(seconds * 1000L + millisecond.to_int64())
}

///|
/// The number of days in `month` of `year`, in the proleptic Gregorian
/// calendar.
fn days_in_month(year : Int, month : Int) -> Int {
  match month {
    2 =>
      if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 {
        29
      } else {
        28
      }
    4 | 6 | 9 | 11 => 30
    _ => 31
  }
}

///|
/// The number of days from 1970-01-01 to the date `year`-`month`-`day`, in
/// the proleptic Gregorian calendar, for years from 0 to 9999.
fn days_from_civil(year : Int, month : Int, day : Int) -> Int {
  // Years start in March, so that the leap day ends them.
  let y = if month <= 2 { year - 1 } else { year }
  let era = (if y >= 0 { y } else { y - 399 }) / 400
  let year_of_era = y - era * 400
  let m = if month > 2 { month - 3 } else { month + 9 }
  let day_of_year = (153 * m + 2) / 5 + day - 1
  let day_of_era = year_of_era * 365 +
    year_of_era / 4 -
    year_of_era / 100 +
    day_of_year
  era * 146097 + day_of_era - 719468
}
