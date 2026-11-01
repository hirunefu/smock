///|
/// A structured logger that writes every entry as one JSON object on one line,
/// such as
/// `{"time":"2026-10-12T14:30:05.123Z","level":"info","msg":"listening","port":8080}`.
///
/// Each entry has the time (RFC 3339, UTC, milliseconds), the level (`info`,
/// `warn` or `error`), the message, and then its structured fields, in the
/// shape its `Format` gives.
///
/// The logger does no I/O itself: it hands each line to `write_line` and asks
/// `now` for the time, so the caller decides where lines go and which clock
/// they carry.
pub struct Logger {
  priv format : Format
  priv write_line : (String) -> Unit
  priv now : () -> Int64
}

///|
/// The shape of a logger's entries.
pub(all) enum Format {
  /// smock's own shape: `time`, `level` and `msg` first, then the fields in
  /// the order given, such as
  /// `{"time":"2026-10-12T14:30:05.123Z","level":"info","msg":"listening","port":8080}`.
  Json
  /// The Mockoon CLI's envelope: `app` (`"smock"`), `level`, `message` and
  /// `timestamp`, with the fields beside them, and the keys sorted at every
  /// depth in UTF-16 code-unit order, as Mockoon's logger sorts them, such as
  /// `{"app":"smock","level":"info","message":"listening","port":8080,"timestamp":"2026-10-12T14:30:05.123Z"}`.
  Mockoon
}

///|
/// Creates a logger.
///
/// - `format` is the shape of its entries, `Json` by default.
/// - `write_line` receives each entry as one line of JSON, without the
///   trailing newline.
/// - `now` returns the current time in milliseconds since the Unix epoch.
pub fn Logger::Logger(
  format~ : Format = Json,
  write_line~ : (String) -> Unit,
  now~ : () -> Int64,
) -> Logger {
  { format, write_line, now, }
}

///|
/// Writes an entry at level `info`. `fields` follow the message as
/// top-level keys of the entry, in the order given, or sorted with the
/// envelope's keys in the `Mockoon` format. A field named like one of the
/// entry's own keys, `time`, `level` or `msg` in the `Json` format, `app`,
/// `level`, `message` or `timestamp` in the `Mockoon` format, is written as
/// `fields.<name>`, such as `fields.level`, so it never replaces the
/// entry's own.
pub fn Logger::info(
  self : Logger,
  msg : String,
  fields~ : Map[String, Json] = {},
) -> Unit {
  self.write("info", msg, fields)
}

///|
/// Writes an entry at level `warn`. `fields` are as for `info`.
pub fn Logger::warn(
  self : Logger,
  msg : String,
  fields~ : Map[String, Json] = {},
) -> Unit {
  self.write("warn", msg, fields)
}

///|
/// Writes an entry at level `error`. `fields` are as for `info`.
pub fn Logger::error(
  self : Logger,
  msg : String,
  fields~ : Map[String, Json] = {},
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
  if self.format is Mockoon {
    (self.write_line)(mockoon_entry(level, msg, fields, (self.now)()))
    return
  }
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
  let out = StringBuilder(size_hint=24)
  write_time(out, ms)
  out.to_string()
}

///|
/// Writes the time `ms`, in milliseconds since the Unix epoch, to `out` as
/// `format_time` formats it, with no string for each number.
fn write_time(out : StringBuilder, ms : Int64) -> Unit {
  let ms_per_day = 86_400_000L
  let days = floor_div(ms, ms_per_day)
  let ms_of_day = ms - days * ms_per_day
  let date = civil_from_days(days)
  write_padded(out, date.year, 4)
  out.write_char('-')
  write_padded(out, date.month, 2)
  out.write_char('-')
  write_padded(out, date.day, 2)
  out.write_char('T')
  write_padded(out, ms_of_day / 3_600_000L, 2)
  out.write_char(':')
  write_padded(out, ms_of_day / 60_000L % 60L, 2)
  out.write_char(':')
  write_padded(out, ms_of_day / 1000L % 60L, 2)
  out.write_char('.')
  write_padded(out, ms_of_day % 1000L, 3)
  out.write_char('Z')
}

///|
/// `a` divided by `b`, rounded toward negative infinity.
pub fn floor_div(a : Int64, b : Int64) -> Int64 {
  let q = a / b
  if a % b != 0L && (a < 0L) != (b < 0L) {
    q - 1L
  } else {
    q
  }
}

///|
/// Writes `n` in decimal to `out`, with zeros before it up to `width`
/// characters, and no string for its digits unless it is negative.
fn write_padded(out : StringBuilder, n : Int64, width : Int32) -> Unit {
  if n < 0L {
    let digits = n.to_string()
    for _ in digits.length()..<width {
      out.write_char('0')
    }
    out.write_string(digits)
    return
  }
  for _ in decimal_length(n)..<width {
    out.write_char('0')
  }
  write_decimal(out, n)
}

///|
/// Writes `n` in decimal to `out`, with no string for its digits unless it
/// is negative.
fn write_decimal(out : StringBuilder, n : Int64) -> Unit {
  if n < 0L {
    out.write_string(n.to_string())
    return
  }
  // The place value of the first digit.
  let mut unit = 1L
  while n / unit >= 10L {
    unit *= 10L
  }
  while unit > 0L {
    out.write_char((0x30 + (n / unit % 10L).to_int()).unsafe_to_char())
    unit /= 10L
  }
}

///|
/// The number of decimal digits of `n`, which is not negative.
fn decimal_length(n : Int64) -> Int32 {
  let mut count = 1
  let mut rest = n
  while rest >= 10L {
    count += 1
    rest /= 10L
  }
  count
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
  let number = (start : Int32, count : Int32) => {
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
  let at = (i : Int32, chars : String) => {
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
  let days = days_from_civil(year, month, day)
  let seconds = ((days * 24L + hour.to_int64()) * 60L + minute.to_int64()) * 60L +
    second.to_int64() -
    offset_minutes.to_int64() * 60L
  Some(seconds * 1000L + millisecond.to_int64())
}

///|
/// The number of days in `month` of `year`, in the proleptic Gregorian
/// calendar.
pub fn days_in_month(year : Int32, month : Int32) -> Int32 {
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
/// the proleptic Gregorian calendar, for years from 0 to 9999, after Howard
/// Hinnant's `days_from_civil`. `civil_from_days` is its inverse.
pub fn days_from_civil(year : Int32, month : Int32, day : Int32) -> Int64 {
  // Years start in March, so that the leap day ends them.
  let y = (if month <= 2 { year - 1 } else { year }).to_int64()
  let era = floor_div(y, 400L)
  let year_of_era = y - era * 400L
  let m = (if month > 2 { month - 3 } else { month + 9 }).to_int64()
  let day_of_year = (153L * m + 2L) / 5L + day.to_int64() - 1L
  let day_of_era = year_of_era * 365L +
    year_of_era / 4L -
    year_of_era / 100L +
    day_of_year
  era * 146_097L + day_of_era - 719_468L
}

///|
/// A date in the proleptic Gregorian calendar, as `civil_from_days` gives
/// it. It is a value type, so returning one builds nothing.
#valtype
pub struct CivilDate {
  year : Int64
  /// From 1 to 12.
  month : Int64
  /// From 1 to 31.
  day : Int64
}

///|
/// The date `days` days after 1970-01-01, before it when negative, in the
/// proleptic Gregorian calendar, after Howard Hinnant's `civil_from_days`.
/// `days_from_civil` is its inverse.
pub fn civil_from_days(days : Int64) -> CivilDate {
  // Years start in March, so that the leap day ends them.
  let z = days + 719_468L
  let era = floor_div(z, 146_097L)
  let doe = z - era * 146_097L
  let yoe = (doe - doe / 1460L + doe / 36_524L - doe / 146_096L) / 365L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let day = doy - (153L * mp + 2L) / 5L + 1L
  let month = if mp < 10L { mp + 3L } else { mp - 9L }
  let year = yoe + era * 400L + (if month <= 2L { 1L } else { 0L })
  { year, month, day, }
}
