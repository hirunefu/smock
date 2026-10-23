// Dates for the date helpers: formats, read when a template is parsed, and
// the calendar they are written on. A date is an instant, in milliseconds
// since the Unix epoch, on the proleptic Gregorian calendar, from the year
// 0 to 9999. Formats use date-fns tokens and write what date-fns writes,
// with English names only, so no output depends on a locale, except that
// the year 0 is written 0000, as RFC 3339 writes it.

///|
/// A part of a date format: text written as it is, or a token.
priv enum DatePart {
  /// Text written as it is: characters that are not letters, and quoted
  /// text.
  Written(String)
  /// `yyyy` or `yy`: the calendar year, in that many digits.
  CalendarYear(Int32)
  /// `M` or `MM`: the month's number, with a leading zero for `MM`;
  /// `MMM` or `MMMM`: its name, short or long.
  MonthOfYear(Int32)
  /// `d` or `dd`: the day of the month.
  DayOfMonth(Int32)
  /// `H` or `HH`: the hour from 0 to 23.
  Hour(Int32)
  /// `h` or `hh`: the hour from 1 to 12.
  Hour12(Int32)
  /// `a`: `AM` or `PM`.
  DayPeriod
  /// `m` or `mm`: the minute.
  MinuteOfHour(Int32)
  /// `s` or `ss`: the second.
  SecondOfMinute(Int32)
  /// `S`, `SS` or `SSS`: tenths, hundredths or milliseconds of the second.
  Fraction(Int32)
  /// `EEE` or `EEEE`: the day of the week, short or long.
  Weekday(Int32)
  /// `X`, `XX` or `XXX` (true): the offset, `Z` when it is zero; `x`, `xx`
  /// or `xxx` (false): the offset, `+00` forms when it is zero.
  Offset(Bool, Int32)
  /// `t`: seconds since the Unix epoch.
  EpochSeconds
  /// `T`: milliseconds since the Unix epoch.
  EpochMillis
}

///|
/// The parts of the date format `format`, or what is wrong with it.
fn date_format(format : String) -> Result[Array[DatePart], String] {
  let chars : Array[Char] = format.iter().collect()
  let parts : Array[DatePart] = []
  // Text not written to `parts` yet.
  let text = StringBuilder()
  let mut i = 0
  while i < chars.length() {
    let c = chars[i]
    if c == '\'' {
      // `''` is one quote, here and inside quoted text.
      if i + 1 < chars.length() && chars[i + 1] == '\'' {
        text.write_char('\'')
        i += 2
        continue
      }
      let mut j = i + 1
      let mut closed = false
      while j < chars.length() {
        if chars[j] == '\'' {
          if j + 1 < chars.length() && chars[j + 1] == '\'' {
            text.write_char('\'')
            j += 2
            continue
          }
          closed = true
          break
        }
        text.write_char(chars[j])
        j += 1
      }
      if !closed {
        return Err(
          "the format \{format.escape()} has a quote that is not closed; write '' for a quote",
        )
      }
      i = j + 1
      continue
    }
    if !c.is_ascii_alphabetic() {
      text.write_char(c)
      i += 1
      continue
    }
    let mut j = i + 1
    while j < chars.length() && chars[j] == c {
      j += 1
    }
    let count = j - i
    let run = String::from_array(chars[i:j])
    let part : DatePart = match (c, count) {
      ('y', 2 | 4) => CalendarYear(count)
      ('M', 1 | 2 | 3 | 4) => MonthOfYear(count)
      ('d', 1 | 2) => DayOfMonth(count)
      ('H', 1 | 2) => Hour(count)
      ('h', 1 | 2) => Hour12(count)
      ('a', 1) => DayPeriod
      ('m', 1 | 2) => MinuteOfHour(count)
      ('s', 1 | 2) => SecondOfMinute(count)
      ('S', 1 | 2 | 3) => Fraction(count)
      ('E', 3 | 4) => Weekday(count)
      ('X', 1 | 2 | 3) => Offset(true, count)
      ('x', 1 | 2 | 3) => Offset(false, count)
      ('t', 1) => EpochSeconds
      ('T', 1) => EpochMillis
      _ => return Err(token_problem(format, c, run))
    }
    if !text.is_empty() {
      parts.push(Written(text.to_string()))
      text.reset()
    }
    parts.push(part)
    i = j
  }
  if !text.is_empty() {
    parts.push(Written(text.to_string()))
  }
  Ok(parts)
}

///|
/// What is wrong with `run`, a run of the letter `letter` in the date
/// format `format`, which is not a token.
fn token_problem(format : String, letter : Char, run : String) -> String {
  let has = "the format \{format.escape()} has \{run}"
  let lengths = match letter {
    'y' => "yyyy or yy"
    'M' => "M, MM, MMM or MMMM"
    'd' => "d or dd"
    'H' => "H or HH"
    'h' => "h or hh"
    'a' => "a"
    'm' => "m or mm"
    's' => "s or ss"
    'S' => "S, SS or SSS"
    'E' => "EEE or EEEE"
    'X' => "X, XX or XXX"
    'x' => "x, xx or xxx"
    't' => "t"
    'T' => "T"
    'Y' =>
      return "\{has}, the week-numbering year: write yyyy or yy for the calendar year"
    'D' =>
      return "\{has}, the day of the year: write dd or d for the day of the month"
    _ =>
      return "\{has}, which is not a token; quote letters to write them as they are, as in 'at'"
  }
  "\{has}, but \{letter} is written \{lengths}"
}

///|
/// The instant the date `json` gives: an RFC 3339 date-time with an
/// offset, a date `YYYY-MM-DD` at UTC midnight, or a number without a
/// fraction, read as milliseconds since the Unix epoch. A number beyond
/// 2^53 - 1 either way is clamped to it, outside the years 0 to 9999.
/// `None` for anything else.
fn date_of(json : Json) -> Int64? {
  match json {
    // Only a date `YYYY-MM-DD` has 10 characters and parses with a time.
    String(text) if text.length() == 10 => @log.parse_time("\{text}T00:00:00Z")
    String(text) => @log.parse_time(text)
    Number(n, ..) if n == n.floor() =>
      if n > max_integer.to_double() {
        Some(max_integer)
      } else if n < -max_integer.to_double() {
        Some(-max_integer)
      } else {
        Some(n.to_int64())
      }
    _ => None
  }
}

///|
/// The offset `text` gives, in minutes: `Z`, or `+HH:MM` or `-HH:MM` with
/// `HH` up to 23 and `MM` up to 59, as RFC 3339 writes one. `None` for
/// anything else: there are no zone names.
fn offset_of(text : String) -> Int32? {
  if text == "Z" {
    return Some(0)
  }
  let c : Array[Char] = text.iter().collect()
  guard c.length() == 6 &&
    c[0] is ('+' | '-') &&
    two_digits(c, 1) is Some(hours) &&
    c[3] == ':' &&
    two_digits(c, 4) is Some(minutes) &&
    hours <= 23 &&
    minutes <= 59 else {
    return None
  }
  let offset = hours * 60 + minutes
  Some(if c[0] == '-' { -offset } else { offset })
}

///|
/// The number the two digits of `c` from `i` write, if they are digits.
fn two_digits(c : Array[Char], i : Int32) -> Int32? {
  guard c[i] is ('0'..<='9') && c[i + 1] is ('0'..<='9') else { return None }
  Some((c[i].to_int() - '0'.to_int()) * 10 + (c[i + 1].to_int() - '0'.to_int()))
}

///|
/// A shift by an ISO 8601 duration: months, then days, then milliseconds,
/// each with the duration's sign.
priv struct Shift {
  months : Int64
  days : Int64
  ms : Int64
}

///|
/// The shift that the ISO 8601 duration `text` gives, such as `P1M`,
/// `-P2D` or `PT90M`, with an optional sign. `Err` holds what is wrong
/// with it, or `None` when it is not a duration at all.
fn shift_of(text : String) -> Result[Shift, String?] {
  let c : Array[Char] = text.iter().collect()
  let mut i = if c.length() > 0 && c[0] is ('+' | '-') { 1 } else { 0 }
  let sign = if i == 1 && c[0] == '-' { -1L } else { 1L }
  guard i < c.length() && c[i] == 'P' else { return Err(None) }
  i += 1
  // The amounts of Y, M, D, then H, M, S after `T`, and the last of them
  // read so far, so that each comes once, in that order.
  let amounts = FixedArray::make(6, 0L)
  let mut last = -1
  let mut time = false
  while i < c.length() {
    if c[i] == 'T' && !time {
      time = true
      last = 2
      i += 1
      guard i < c.length() else { return Err(None) }
      continue
    }
    let start = i
    let mut amount = 0L
    while i < c.length() && c[i] is ('0'..<='9') {
      amount = amount * 10L + (c[i].to_int() - '0'.to_int()).to_int64()
      i += 1
      if i - start > 9 {
        return Err(
          Some(
            "the duration \{text.escape()} has an amount of more than 9 digits",
          ),
        )
      }
    }
    guard i > start && i < c.length() else { return Err(None) }
    let unit = match (time, c[i]) {
      (_, '.' | ',') =>
        return Err(
          Some(
            "the duration \{text.escape()} has a fraction; write whole amounts, such as 'PT90M'",
          ),
        )
      (false, 'W') =>
        return Err(
          Some(
            "the duration \{text.escape()} has weeks, which a shift does not take; write days, such as 'P14D'",
          ),
        )
      (false, 'Y') => 0
      (false, 'M') => 1
      (false, 'D') => 2
      (true, 'H') => 3
      (true, 'M') => 4
      (true, 'S') => 5
      _ => return Err(None)
    }
    guard unit > last else { return Err(None) }
    amounts[unit] = amount
    last = unit
    i += 1
  }
  guard last >= 0 && (!time || last > 2) else { return Err(None) }
  Ok({
    months: sign * (amounts[0] * 12L + amounts[1]),
    days: sign * amounts[2],
    ms: sign * ((amounts[3] * 60L + amounts[4]) * 60L + amounts[5]) * 1000L,
  })
}

///|
/// The instant `ms` shifted by `shift` on the UTC calendar: years and
/// months first, the day clamped to the end of the month, then days, then
/// the time. `None` when the result is outside the years 0 to 9999.
fn shifted(ms : Int64, shift : Shift) -> Int64? {
  let mut days = @log.floor_div(ms, day_ms)
  let of_day = ms - days * day_ms
  if shift.months != 0L {
    let date = civil(ms)
    let months = date.year.to_int64() * 12L +
      (date.month - 1).to_int64() +
      shift.months
    let year = @log.floor_div(months, 12L)
    if year < 0L || year > 9999L {
      return None
    }
    let month = (months - year * 12L).to_int() + 1
    let last_day = @log.days_in_month(year.to_int(), month)
    days = @log.days_from_civil(
      year.to_int(),
      month,
      if date.day > last_day {
        last_day
      } else {
        date.day
      },
    )
  }
  let result = (days + shift.days) * day_ms + of_day + shift.ms
  if result < earliest || result > latest {
    None
  } else {
    Some(result)
  }
}

///|
/// The first instant a date can be, 0000-01-01T00:00:00.000Z, which RFC
/// 3339 can write.
let earliest : Int64 = -62_167_219_200_000L

///|
/// The last instant a date can be, 9999-12-31T23:59:59.999Z.
let latest : Int64 = 253_402_300_799_999L

///|
/// Raises a render error at `at`, from the helper `name`, when the instant
/// `ms` is outside the years 0 to 9999.
fn check_years(
  name : String,
  ms : Int64,
  at : String,
) -> Unit raise RenderError {
  if ms < earliest || ms > latest {
    raise outside_years(name, at)
  }
}

///|
/// The render error at `at` of the helper `name` whose date, or result,
/// is outside the years 0 to 9999.
fn outside_years(name : String, at : String) -> RenderError {
  RenderError(at~, message="\{name}(): the time is outside the years 0 to 9999")
}

///|
/// The milliseconds of a day.
let day_ms : Int64 = 86_400_000L

///|
/// The English names of the months.
let month_names : Array[String] = [
  "January", "February", "March", "April", "May", "June", "July", "August", "September",
  "October", "November", "December",
]

///|
/// The English names of the days of the week, from Sunday.
let weekday_names : Array[String] = [
  "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
]

///|
/// The fields of an instant on the calendar.
priv struct Civil {
  year : Int32
  /// From 1 to 12.
  month : Int32
  /// From 1 to 31.
  day : Int32
  /// From 0, Sunday, to 6, Saturday.
  weekday : Int32
  /// From 0 to 23.
  hour : Int32
  minute : Int32
  second : Int32
  milli : Int32
}

///|
/// The date and time of the instant `ms`.
fn civil(ms : Int64) -> Civil {
  let days = @log.floor_div(ms, day_ms)
  let of_day = (ms - days * day_ms).to_int()
  let (year, month, day) = @log.civil_from_days(days)
  {
    year: year.to_int(),
    month: month.to_int(),
    day: day.to_int(),
    // 1970-01-01 was a Thursday.
    weekday: (days - @log.floor_div(days, 7L) * 7L + 4L).to_int() % 7,
    hour: of_day / 3_600_000,
    minute: of_day / 60_000 % 60,
    second: of_day / 1000 % 60,
    milli: of_day % 1000,
  }
}

///|
/// The instant `ms` written in the format `parts`, at the offset `offset`
/// in minutes, by the helper `name` for the field at `at`. Raises a render
/// error when the time at that offset is outside the years 0 to 9999, or
/// when the result takes more than 1 MiB.
fn written_date(
  parts : Array[DatePart],
  ms : Int64,
  offset : Int32,
  name : String,
  at : String,
) -> String raise RenderError {
  let at_offset = ms + offset.to_int64() * 60_000L
  check_years(name, at_offset, at)
  let date = civil(at_offset)
  let out = StringBuilder()
  // The UTF-8 bytes written so far.
  let mut bytes = 0L
  for part in parts {
    let piece = match part {
      Written(text) => text
      // The year 0 is 0000, as smock's RFC 3339 times write it, where
      // date-fns writes the year of the era, 0001 (1 BC).
      CalendarYear(2) => zero_padded(date.year % 100, 2)
      CalendarYear(digits) => zero_padded(date.year, digits)
      MonthOfYear(1 | 2 as digits) => zero_padded(date.month, digits)
      MonthOfYear(3) =>
        month_names[date.month - 1].view(end_offset=3).to_owned()
      MonthOfYear(_) => month_names[date.month - 1]
      DayOfMonth(digits) => zero_padded(date.day, digits)
      Hour(digits) => zero_padded(date.hour, digits)
      Hour12(digits) =>
        zero_padded(
          if date.hour % 12 == 0 {
            12
          } else {
            date.hour % 12
          },
          digits,
        )
      DayPeriod => if date.hour < 12 { "AM" } else { "PM" }
      MinuteOfHour(digits) => zero_padded(date.minute, digits)
      SecondOfMinute(digits) => zero_padded(date.second, digits)
      Fraction(1) => zero_padded(date.milli / 100, 1)
      Fraction(2) => zero_padded(date.milli / 10, 2)
      Fraction(_) => zero_padded(date.milli, 3)
      Weekday(3) => weekday_names[date.weekday].view(end_offset=3).to_owned()
      Weekday(_) => weekday_names[date.weekday]
      Offset(zulu, width) => written_offset(offset, zulu, width)
      // Rounded toward zero, as date-fns does.
      EpochSeconds => (ms / 1000L).to_string()
      EpochMillis => ms.to_string()
    }
    bytes += utf8_length(piece).to_int64()
    check_result(name, bytes, at)
    out.write_string(piece)
  }
  out.to_string()
}

///|
/// The offset `offset`, in minutes, as the token `X` (`zulu`) or `x`
/// written `width` times writes it: `Z` for zero with `X`; otherwise
/// `+09` (`+0530` when the minutes are not zero), `+0900` or `+09:00`.
fn written_offset(offset : Int32, zulu : Bool, width : Int32) -> String {
  if offset == 0 && zulu {
    return "Z"
  }
  let sign = if offset < 0 { "-" } else { "+" }
  let hours = zero_padded(offset.abs() / 60, 2)
  let minutes = zero_padded(offset.abs() % 60, 2)
  match width {
    1 if offset.abs() % 60 == 0 => "\{sign}\{hours}"
    1 | 2 => "\{sign}\{hours}\{minutes}"
    _ => "\{sign}\{hours}:\{minutes}"
  }
}

///|
/// `n`, which is not negative, written with at least `digits` digits.
fn zero_padded(n : Int32, digits : Int32) -> String {
  let text = n.to_string()
  if text.length() >= digits {
    return text
  }
  let out = StringBuilder()
  for _ in text.length()..<digits {
    out.write_char('0')
  }
  out.write_string(text)
  out.to_string()
}
