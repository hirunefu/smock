///|
/// The value of a response's Date field (RFC 9110, section 6.6.1): a time
/// in IMF-fixdate form (section 5.6.7), such as
/// `Sun, 06 Nov 1994 08:49:37 GMT`. It reads no clock: the caller passes
/// the time. The value is formatted at most once per second: `at` gives the
/// value it gave last, unchanged, while the time stays in the same second.
///
/// ```mbt check
/// test {
///   let dates = @http1.DateCache()
///   inspect(dates.at(784111777000L), content="Sun, 06 Nov 1994 08:49:37 GMT")
/// }
/// ```
pub struct DateCache {
  /// The second of `value`, in seconds since the epoch.
  priv mut second : Int64
  priv mut value : String
}

///|
/// A cache that has formatted no time yet.
pub fn DateCache::DateCache() -> DateCache {
  { second: 0L, value: http_date(0L), }
}

///|
/// The Date value for the time `ms`, in milliseconds since the epoch, as
/// `@async.now()` gives it: the second it falls in, in IMF-fixdate form.
pub fn DateCache::at(self : DateCache, ms : Int64) -> String {
  let second = floor_div(ms, 1000L)
  if second != self.second {
    self.second = second
    self.value = http_date(second)
  }
  self.value
}

///|
/// The time `seconds` after the epoch in IMF-fixdate form, in the proleptic
/// Gregorian calendar.
fn http_date(seconds : Int64) -> String {
  let days = floor_div(seconds, 86_400L)
  let second_of_day = seconds - days * 86_400L
  // After Howard Hinnant's `civil_from_days`. Years start in March, so
  // that the leap day ends them.
  let z = days + 719_468L
  let era = floor_div(z, 146_097L)
  let doe = z - era * 146_097L
  let yoe = (doe - doe / 1460L + doe / 36_524L - doe / 146_096L) / 365L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let day = doy - (153L * mp + 2L) / 5L + 1L
  let month = if mp < 10L { mp + 3L } else { mp - 9L }
  let year = yoe + era * 400L + (if month <= 2L { 1L } else { 0L })
  // 1970-01-01 was a Thursday.
  let weekday = (days + 4L - floor_div(days + 4L, 7L) * 7L).to_int()
  let out = StringBuilder(size_hint=29)
  out.write_string(weekday_names[weekday])
  out.write_string(", ")
  write_padded(out, day, 2)
  out.write_char(' ')
  out.write_string(month_names[month.to_int() - 1])
  out.write_char(' ')
  write_padded(out, year, 4)
  out.write_char(' ')
  write_padded(out, second_of_day / 3600L, 2)
  out.write_char(':')
  write_padded(out, second_of_day / 60L % 60L, 2)
  out.write_char(':')
  write_padded(out, second_of_day % 60L, 2)
  out.write_string(" GMT")
  out.to_string()
}

///|
/// The names of the days of the week in IMF-fixdate, from Sunday.
let weekday_names : FixedArray[String] = [
  "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat",
]

///|
/// The names of the months in IMF-fixdate, from January.
let month_names : FixedArray[String] = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
]

///|
/// Writes `n`, which is not negative, in decimal with zeros before it up to
/// `width` digits.
fn write_padded(out : StringBuilder, n : Int64, width : Int) -> Unit {
  let digits = n.to_string()
  for _ in digits.length()..<width {
    out.write_char('0')
  }
  out.write_string(digits)
}

///|
/// `a` divided by `b`, which is positive, rounded toward negative infinity.
fn floor_div(a : Int64, b : Int64) -> Int64 {
  let q = a / b
  if a % b < 0L {
    q - 1L
  } else {
    q
  }
}
