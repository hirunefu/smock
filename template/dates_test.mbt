// Tests of the date helpers through the template package's public
// interface: `now(format)`, `dateFormat` and `dateTimeShift`. The expected
// outputs are what date-fns 4.4.0 writes for the same instants. They run on
// native and on wasm-gc, and give the same output on both.

///|
test "now(format) writes the time of the request in UTC, in the format" {
  inspect(rendered("${now('yyyy-MM-dd')}"), content="2026-10-13")
}

///|
/// What the body template `source` renders for a request received at
/// `now` (milliseconds since the Unix epoch), or its problem or render
/// error, on one line.
fn rendered_at(source : String, now : Int64) -> String {
  match
    @template.Text::parse(source, pointer="/response/body", kind=Body(Plain)) {
    Ok(text) =>
      text.render(
        @template.Context::new(
          request,
          now~,
          rand=@template.helper_generator(1),
        ),
      ) catch {
        RenderError(at~, message~) => "error at \{at}: \{message}"
      }
    Err(problem) => "problem at \{problem.pointer}: \{problem.message}"
  }
}

///|
/// Every token, then quoted text, a quote and other characters.
let every_token : String = "yyyy yy M MM MMM MMMM d dd H HH h hh a m mm s ss S SS SSS EEE EEEE X XX XXX x xx xxx t T 'o''clock' '' —"

///|
test "each token writes what date-fns writes for it, in English, except that yyyy and yy write the year 0 as 0000 and 00: on single-digit fields, at midnight and noon, before 1970, and at the first and last instants of the years 0 to 9999" {
  let instants = [
    1_772_719_628_045L, // 2026-03-05T14:07:08.045Z
     1_798_157_349_999L, // 2026-12-25T00:09:09.999Z
     1_791_894_600_500L, // 2026-10-13T12:30:00.500Z
     -500L, // 1969-12-31T23:59:59.500Z
     -62_009_268_954_994L, // 0005-01-02T03:04:05.006Z
     -62_167_219_200_000L, // 0000-01-01T00:00:00.000Z
     253_402_300_799_999L, // 9999-12-31T23:59:59.999Z
  ]
  inspect(
    instants
    .map(now => {
      rendered_at("${now(\{Json::string(every_token).stringify()})}", now)
    })
    .join("\n"),
    content=(
      #|2026 26 3 03 Mar March 5 05 14 14 2 02 PM 7 07 8 08 0 04 045 Thu Thursday Z Z Z +00 +0000 +00:00 1772719628 1772719628045 o'clock ' —
      #|2026 26 12 12 Dec December 25 25 0 00 12 12 AM 9 09 9 09 9 99 999 Fri Friday Z Z Z +00 +0000 +00:00 1798157349 1798157349999 o'clock ' —
      #|2026 26 10 10 Oct October 13 13 12 12 12 12 PM 30 30 0 00 5 50 500 Tue Tuesday Z Z Z +00 +0000 +00:00 1791894600 1791894600500 o'clock ' —
      #|1969 69 12 12 Dec December 31 31 23 23 11 11 PM 59 59 59 59 5 50 500 Wed Wednesday Z Z Z +00 +0000 +00:00 0 -500 o'clock ' —
      #|0005 05 1 01 Jan January 2 02 3 03 3 03 AM 4 04 5 05 0 00 006 Sun Sunday Z Z Z +00 +0000 +00:00 -62009268954 -62009268954994 o'clock ' —
      #|0000 00 1 01 Jan January 1 01 0 00 12 12 AM 0 00 0 00 0 00 000 Sat Saturday Z Z Z +00 +0000 +00:00 -62167219200 -62167219200000 o'clock ' —
      #|9999 99 12 12 Dec December 31 31 23 23 11 11 PM 59 59 59 59 9 99 999 Fri Friday Z Z Z +00 +0000 +00:00 253402300799 253402300799999 o'clock ' —
    ),
  )
}

///|
test "characters that are not ASCII letters are written as they are, letters beyond ASCII included, and an empty format writes nothing" {
  inspect(
    [rendered("${now('é ü 12 _ 日本 [d]')}"), rendered("[${now('')}]")].join(
      "\n",
    ),
    content=(
      #|é ü 12 _ 日本 [13]
      #|[]
    ),
  )
}

///|
test "the week-numbering year, the day of the year, any other letter, a run of a listed letter of another length, and a quote that is not closed are load errors" {
  inspect(
    [
      "${now('YYYY-MM-dd')}", "${now('YY')}", "${now('Y')}", "${now('yyyy-MM-DD')}",
      "${now('D')}", "${now('Do MMMM')}", "${now('q')}", "${now('yyy')}", "${now('y')}",
      "${now('MMMMM')}", "${now('E')}", "${now('EE')}", "${now('SSSS')}", "${now('XXXX')}",
      "${now('xxxx')}", "${now('aa')}", "${now('tt')}", "${now('ddd')}", "${now(\"'at\")}",
      "${now(\"'it''s\")}",
    ]
    .map(source => rendered(source))
    .join("\n"),
    content=(
      #|problem at /response/body: template: column 7: now(): the format "YYYY-MM-dd" has YYYY, the week-numbering year: write yyyy or yy for the calendar year
      #|problem at /response/body: template: column 7: now(): the format "YY" has YY, the week-numbering year: write yyyy or yy for the calendar year
      #|problem at /response/body: template: column 7: now(): the format "Y" has Y, the week-numbering year: write yyyy or yy for the calendar year
      #|problem at /response/body: template: column 7: now(): the format "yyyy-MM-DD" has DD, the day of the year: write dd or d for the day of the month
      #|problem at /response/body: template: column 7: now(): the format "D" has D, the day of the year: write dd or d for the day of the month
      #|problem at /response/body: template: column 7: now(): the format "Do MMMM" has D, the day of the year: write dd or d for the day of the month
      #|problem at /response/body: template: column 7: now(): the format "q" has q, which is not a token; quote letters to write them as they are, as in 'at'
      #|problem at /response/body: template: column 7: now(): the format "yyy" has yyy, but y is written yyyy or yy
      #|problem at /response/body: template: column 7: now(): the format "y" has y, but y is written yyyy or yy
      #|problem at /response/body: template: column 7: now(): the format "MMMMM" has MMMMM, but M is written M, MM, MMM or MMMM
      #|problem at /response/body: template: column 7: now(): the format "E" has E, but E is written EEE or EEEE
      #|problem at /response/body: template: column 7: now(): the format "EE" has EE, but E is written EEE or EEEE
      #|problem at /response/body: template: column 7: now(): the format "SSSS" has SSSS, but S is written S, SS or SSS
      #|problem at /response/body: template: column 7: now(): the format "XXXX" has XXXX, but X is written X, XX or XXX
      #|problem at /response/body: template: column 7: now(): the format "xxxx" has xxxx, but x is written x, xx or xxx
      #|problem at /response/body: template: column 7: now(): the format "aa" has aa, but a is written a
      #|problem at /response/body: template: column 7: now(): the format "tt" has tt, but t is written t
      #|problem at /response/body: template: column 7: now(): the format "ddd" has ddd, but d is written d or dd
      #|problem at /response/body: template: column 7: now(): the format "'at" has a quote that is not closed; write '' for a quote
      #|problem at /response/body: template: column 7: now(): the format "'it''s" has a quote that is not closed; write '' for a quote
    ),
  )
}

///|
test "a format is a string literal" {
  inspect(
    [
      "${now(query.f)}", "${now(query.f ?? 'yyyy')}", "${now(true)}", "${now('yyyy', 1)}",
      "${nowMillis('yyyy')}",
    ]
    .map(source => rendered(source))
    .join("\n"),
    content=(
      #|problem at /response/body: template: column 7: now(): argument 1 must be a format, a string literal such as 'yyyy-MM-dd', or seconds, an integer literal from -9007199254740991 to 9007199254740991
      #|problem at /response/body: template: column 7: now(): argument 1 must be a format, a string literal such as 'yyyy-MM-dd', or seconds, an integer literal from -9007199254740991 to 9007199254740991
      #|problem at /response/body: template: column 7: now(): argument 1 must be a format, a string literal such as 'yyyy-MM-dd', or seconds, an integer literal from -9007199254740991 to 9007199254740991
      #|problem at /response/body: template: column 3: now() takes 0 or 1 argument, not 2
      #|problem at /response/body: template: column 13: nowMillis(): argument 1 must be an integer literal from -9007199254740991 to 9007199254740991
    ),
  )
}

///|
/// A request whose body holds dates, and values that are not dates.
let dated : @template.Input = {
  meth: "GET",
  path: "/",
  query: [("day", "2026-01-31"), ("ts", "1769853600000")],
  headers: [],
  body: @utf8.encode(
    (
      #|{ "utc": "2026-01-31T10:00:00Z", "offset": "2026-01-31T19:00:00.5+09:00",
      #|  "lower": "2026-01-31t10:00:00.123456z", "day": "2026-02-28",
      #|  "millis": 1769853600000, "negative": -1, "kept": 1769853600000.0,
      #|  "digits": "1769853600000", "fraction": 1769853600000.5,
      #|  "local": "2026-01-31T10:00:00", "space": "2026-01-31 10:00:00Z",
      #|  "february30": "2026-02-30", "february29": "2025-02-29T00:00:00Z",
      #|  "hour24": "2026-01-31T24:00:00Z", "short": "2026-1-31",
      #|  "flag": true, "none": null, "object": {}, "list": [] }
    ),
  ),
}

///|
/// What `dateFormat(<date>, 'yyyy-MM-dd HH:mm:ss.SSS')` renders for each
/// date expression of `dates`, for `dated`, one per line.
fn formatted(dates : Array[String]) -> String {
  dates
  .map(date => {
    rendered("${dateFormat(\{date}, 'yyyy-MM-dd HH:mm:ss.SSS')}", input=dated)
  })
  .join("\n")
}

///|
test "a date is an RFC 3339 date-time with an offset, which is not kept, a date YYYY-MM-DD at UTC midnight, or epoch milliseconds" {
  inspect(
    formatted([
      "body.utc", "body.offset", "body.lower", "body.day", "body.millis", "body.negative",
      "body.kept", "query.day", "now()", "nowMillis()", "'2026-01-31'", "0",
    ]),
    content=(
      #|2026-01-31 10:00:00.000
      #|2026-01-31 10:00:00.500
      #|2026-01-31 10:00:00.123
      #|2026-02-28 00:00:00.000
      #|2026-01-31 10:00:00.000
      #|1969-12-31 23:59:59.999
      #|2026-01-31 10:00:00.000
      #|2026-01-31 00:00:00.000
      #|2026-10-13 09:00:00.000
      #|2026-10-13 09:00:00.000
      #|2026-01-31 00:00:00.000
      #|1970-01-01 00:00:00.000
    ),
  )
}

///|
test "anything else is missing, so ?? gives a fallback: a string of digits, a number that is not an integer, a date-time without an offset, a date that does not exist, and other kinds of values" {
  let missing = [
    "query.ts", "body.digits", "body.fraction", "body.local", "body.space", "body.february30",
    "body.february29", "body.hour24", "body.short", "body.flag", "body.none", "body.object",
    "body.list",
  ]
  inspect(
    missing
    .map(date => {
      rendered("${dateFormat(\{date}, 'yyyy') ?? 'missing'}", input=dated)
    })
    .join(" "),
    content="missing missing missing missing missing missing missing missing missing missing missing missing missing",
  )
  inspect(
    formatted(["body.digits", "body.absent"]),
    content=(
      #|error at /response/body: dateFormat(body.digits, 'yyyy-MM-dd HH:mm:ss.SSS') is missing
      #|error at /response/body: body.absent is missing
    ),
  )
}

///|
test "dateFormat writes the date at an offset, by default Z: X forms give Z at a zero offset, x forms +00 forms, and epoch times do not move" {
  let offsets = [
    "", ", 'Z'", ", '+09:00'", ", '+05:30'", ", '-03:00'", ", '+23:59'", ", '-23:59'",
    ", '-00:00'",
  ]
  inspect(
    offsets
    .map(offset => {
      rendered(
        "${dateFormat(body.utc, 'yyyy-MM-dd HH:mm EEE X XX XXX x xx xxx t T'\{offset})}",
        input=dated,
      )
    })
    .join("\n"),
    content=(
      #|2026-01-31 10:00 Sat Z Z Z +00 +0000 +00:00 1769853600 1769853600000
      #|2026-01-31 10:00 Sat Z Z Z +00 +0000 +00:00 1769853600 1769853600000
      #|2026-01-31 19:00 Sat +09 +0900 +09:00 +09 +0900 +09:00 1769853600 1769853600000
      #|2026-01-31 15:30 Sat +0530 +0530 +05:30 +0530 +0530 +05:30 1769853600 1769853600000
      #|2026-01-31 07:00 Sat -03 -0300 -03:00 -03 -0300 -03:00 1769853600 1769853600000
      #|2026-02-01 09:59 Sun +2359 +2359 +23:59 +2359 +2359 +23:59 1769853600 1769853600000
      #|2026-01-30 10:01 Fri -2359 -2359 -23:59 -2359 -2359 -23:59 1769853600 1769853600000
      #|2026-01-31 10:00 Sat Z Z Z +00 +0000 +00:00 1769853600 1769853600000
    ),
  )
  inspect(
    rendered(
      "${dateFormat(body.day, 'yyyy-MM-dd HH:mm EEE X', '-01:00')}",
      input=dated,
    ),
    content="2026-02-27 23:00 Fri -01",
  )
}

///|
test "an offset is a string literal, Z or ±HH:MM with HH up to 23 and MM up to 59; there are no zone names" {
  let offsets = [
    "'+9'", "'+09'", "'+0900'", "'+24:00'", "'+09:60'", "'z'", "'UTC'", "'Asia/Tokyo'",
    "'+09:00 '", "''", "'09:00'", "9", "query.tz", "query.tz ?? 'Z'",
  ]
  inspect(
    offsets
    .map(offset => {
      rendered("${dateFormat(body.utc, 'HH', \{offset})}", input=dated)
    })
    .join("\n"),
    content=(
      #|problem at /response/body: template: column 30: dateFormat(): argument 3 must be an offset, a string literal: 'Z', or '+HH:MM' or '-HH:MM' with HH up to 23 and MM up to 59, not "+9"
      #|problem at /response/body: template: column 30: dateFormat(): argument 3 must be an offset, a string literal: 'Z', or '+HH:MM' or '-HH:MM' with HH up to 23 and MM up to 59, not "+09"
      #|problem at /response/body: template: column 30: dateFormat(): argument 3 must be an offset, a string literal: 'Z', or '+HH:MM' or '-HH:MM' with HH up to 23 and MM up to 59, not "+0900"
      #|problem at /response/body: template: column 30: dateFormat(): argument 3 must be an offset, a string literal: 'Z', or '+HH:MM' or '-HH:MM' with HH up to 23 and MM up to 59, not "+24:00"
      #|problem at /response/body: template: column 30: dateFormat(): argument 3 must be an offset, a string literal: 'Z', or '+HH:MM' or '-HH:MM' with HH up to 23 and MM up to 59, not "+09:60"
      #|problem at /response/body: template: column 30: dateFormat(): argument 3 must be an offset, a string literal: 'Z', or '+HH:MM' or '-HH:MM' with HH up to 23 and MM up to 59, not "z"
      #|problem at /response/body: template: column 30: dateFormat(): argument 3 must be an offset, a string literal: 'Z', or '+HH:MM' or '-HH:MM' with HH up to 23 and MM up to 59, not "UTC"
      #|problem at /response/body: template: column 30: dateFormat(): argument 3 must be an offset, a string literal: 'Z', or '+HH:MM' or '-HH:MM' with HH up to 23 and MM up to 59, not "Asia/Tokyo"
      #|problem at /response/body: template: column 30: dateFormat(): argument 3 must be an offset, a string literal: 'Z', or '+HH:MM' or '-HH:MM' with HH up to 23 and MM up to 59, not "+09:00 "
      #|problem at /response/body: template: column 30: dateFormat(): argument 3 must be an offset, a string literal: 'Z', or '+HH:MM' or '-HH:MM' with HH up to 23 and MM up to 59, not ""
      #|problem at /response/body: template: column 30: dateFormat(): argument 3 must be an offset, a string literal: 'Z', or '+HH:MM' or '-HH:MM' with HH up to 23 and MM up to 59, not "09:00"
      #|problem at /response/body: template: column 30: dateFormat(): argument 3 must be an offset, a string literal: 'Z', or '+HH:MM' or '-HH:MM' with HH up to 23 and MM up to 59, not 9
      #|problem at /response/body: template: column 30: dateFormat(): argument 3 must be an offset, a string literal: 'Z', or '+HH:MM' or '-HH:MM' with HH up to 23 and MM up to 59
      #|problem at /response/body: template: column 30: dateFormat(): argument 3 must be an offset, a string literal: 'Z', or '+HH:MM' or '-HH:MM' with HH up to 23 and MM up to 59
    ),
  )
}

///|
test "dateTimeShift applies years and months first, clamped to the end of the month, then days, then the time part, and writes RFC 3339 in UTC with milliseconds" {
  let shifts = [
    ("'2026-01-31T10:00:00Z'", "P1M"),
    ("'2024-01-31'", "P1M"),
    ("'2024-02-29'", "P1Y"),
    ("'2024-02-29'", "P4Y"),
    ("'2024-02-29'", "-P1Y"),
    ("'2026-03-31'", "-P1M"),
    ("'2026-01-31T10:00:00Z'", "P1M1D"),
    ("'2026-02-28'", "P1D"),
    ("'2024-02-28'", "P1D"),
    ("'2026-01-31T10:00:00Z'", "PT90M"),
    ("'2026-01-31T10:00:00Z'", "-P2D"),
    ("'2026-01-31T10:00:00Z'", "P1Y2M3DT4H5M6S"),
    ("'2026-01-31T10:00:00Z'", "-P1Y2M3DT4H5M6S"),
    ("'2026-12-31'", "P1M"),
    ("'2026-01-15'", "-P1M"),
    ("'2026-02-28'", "PT24H"),
    ("body.offset", "PT1S"),
    ("'2026-01-31T10:00:00Z'", "P12M"),
    ("body.millis", "+P1D"),
    ("body.utc", "PT0S"),
  ]
  inspect(
    shifts
    .map(shift => {
      rendered("${dateTimeShift(\{shift.0}, '\{shift.1}')}", input=dated)
    })
    .join("\n"),
    content=(
      #|2026-02-28T10:00:00.000Z
      #|2024-02-29T00:00:00.000Z
      #|2025-02-28T00:00:00.000Z
      #|2028-02-29T00:00:00.000Z
      #|2023-02-28T00:00:00.000Z
      #|2026-02-28T00:00:00.000Z
      #|2026-03-01T10:00:00.000Z
      #|2026-03-01T00:00:00.000Z
      #|2024-02-29T00:00:00.000Z
      #|2026-01-31T11:30:00.000Z
      #|2026-01-29T10:00:00.000Z
      #|2027-04-03T14:05:06.000Z
      #|2024-11-27T05:54:54.000Z
      #|2027-01-31T00:00:00.000Z
      #|2025-12-15T00:00:00.000Z
      #|2026-03-01T00:00:00.000Z
      #|2026-01-31T10:00:01.500Z
      #|2027-01-31T10:00:00.000Z
      #|2026-02-01T10:00:00.000Z
      #|2026-01-31T10:00:00.000Z
    ),
  )
}

///|
test "the ticket's example: a month after January 31 is the last day of February, written at +09:00" {
  inspect(
    rendered_at(
      "${now('yyyy-MM-dd')} ${dateFormat(dateTimeShift(now(), 'P1M'), 'yyyy-MM-dd', '+09:00')}",
      1_769_853_600_000L, // 2026-01-31T10:00:00Z
    ),
    content="2026-01-31 2026-02-28",
  )
}

///|
test "dateTimeShift of what is not a date is missing" {
  inspect(
    [
      rendered("${dateTimeShift(body.digits, 'P1D') ?? 'missing'}", input=dated),
      rendered("${dateTimeShift(body.local, 'P1D')}", input=dated),
    ].join("\n"),
    content=(
      #|missing
      #|error at /response/body: dateTimeShift(body.local, 'P1D') is missing
    ),
  )
}

///|
test "a duration is a string literal; weeks, fractions, an amount of more than 9 digits, and anything else are load errors" {
  let durations = [
    "'P2W'", "'P1W2D'", "'PT1.5H'", "'P0,5D'", "'P1234567890D'", "'P999999999D'",
    "'P'", "'PT'", "'P1DT'", "'P1'", "'p1d'", "'P1D1M'", "'P1Y1Y'", "'PT1M1H'", "'PT2W'",
    "'1 month'", "'--P1D'", "'P-1D'", "1", "query.p", "query.p ?? 'P1D'",
  ]
  inspect(
    durations
    .map(duration => {
      rendered("${dateTimeShift(body.utc, \{duration})}", input=dated)
    })
    .join("\n"),
    content=(
      #|problem at /response/body: template: column 27: dateTimeShift(): the duration "P2W" has weeks, which a shift does not take; write days, such as 'P14D'
      #|problem at /response/body: template: column 27: dateTimeShift(): the duration "P1W2D" has weeks, which a shift does not take; write days, such as 'P14D'
      #|problem at /response/body: template: column 27: dateTimeShift(): the duration "PT1.5H" has a fraction; write whole amounts, such as 'PT90M'
      #|problem at /response/body: template: column 27: dateTimeShift(): the duration "P0,5D" has a fraction; write whole amounts, such as 'PT90M'
      #|problem at /response/body: template: column 27: dateTimeShift(): the duration "P1234567890D" has an amount of more than 9 digits
      #|error at /response/body: dateTimeShift(): the time is outside the years 0 to 9999
      #|problem at /response/body: template: column 27: dateTimeShift(): argument 2 must be a duration, a string literal such as 'P1M', '-P2D' or 'PT90M', not "P"
      #|problem at /response/body: template: column 27: dateTimeShift(): argument 2 must be a duration, a string literal such as 'P1M', '-P2D' or 'PT90M', not "PT"
      #|problem at /response/body: template: column 27: dateTimeShift(): argument 2 must be a duration, a string literal such as 'P1M', '-P2D' or 'PT90M', not "P1DT"
      #|problem at /response/body: template: column 27: dateTimeShift(): argument 2 must be a duration, a string literal such as 'P1M', '-P2D' or 'PT90M', not "P1"
      #|problem at /response/body: template: column 27: dateTimeShift(): argument 2 must be a duration, a string literal such as 'P1M', '-P2D' or 'PT90M', not "p1d"
      #|problem at /response/body: template: column 27: dateTimeShift(): argument 2 must be a duration, a string literal such as 'P1M', '-P2D' or 'PT90M', not "P1D1M"
      #|problem at /response/body: template: column 27: dateTimeShift(): argument 2 must be a duration, a string literal such as 'P1M', '-P2D' or 'PT90M', not "P1Y1Y"
      #|problem at /response/body: template: column 27: dateTimeShift(): argument 2 must be a duration, a string literal such as 'P1M', '-P2D' or 'PT90M', not "PT1M1H"
      #|problem at /response/body: template: column 27: dateTimeShift(): argument 2 must be a duration, a string literal such as 'P1M', '-P2D' or 'PT90M', not "PT2W"
      #|problem at /response/body: template: column 27: dateTimeShift(): argument 2 must be a duration, a string literal such as 'P1M', '-P2D' or 'PT90M', not "1 month"
      #|problem at /response/body: template: column 27: dateTimeShift(): argument 2 must be a duration, a string literal such as 'P1M', '-P2D' or 'PT90M', not "--P1D"
      #|problem at /response/body: template: column 27: dateTimeShift(): argument 2 must be a duration, a string literal such as 'P1M', '-P2D' or 'PT90M', not "P-1D"
      #|problem at /response/body: template: column 27: dateTimeShift(): argument 2 must be a duration, a string literal such as 'P1M', '-P2D' or 'PT90M', not 1
      #|problem at /response/body: template: column 27: dateTimeShift(): argument 2 must be a duration, a string literal such as 'P1M', '-P2D' or 'PT90M'
      #|problem at /response/body: template: column 27: dateTimeShift(): argument 2 must be a duration, a string literal such as 'P1M', '-P2D' or 'PT90M'
    ),
  )
  inspect(
    [
      rendered("${dateTimeShift(body.utc)}", input=dated),
      rendered("${dateTimeShift(body.utc, 'P1D', 'Z')}", input=dated),
      rendered("${dateFormat(body.utc)}", input=dated),
      rendered("${dateFormat(body.utc, 'yyyy', 'Z', 'Z')}", input=dated),
      rendered("${dateFormat(body.utc, query.f)}", input=dated),
      rendered("${dateFormat(body.utc, 5)}", input=dated),
      rendered("${dateFormat(body.utc, 'YYYY')}", input=dated),
    ].join("\n"),
    content=(
      #|problem at /response/body: template: column 3: dateTimeShift() takes 2 arguments, not 1
      #|problem at /response/body: template: column 3: dateTimeShift() takes 2 arguments, not 3
      #|problem at /response/body: template: column 3: dateFormat() takes 2 or 3 arguments, not 1
      #|problem at /response/body: template: column 3: dateFormat() takes 2 or 3 arguments, not 4
      #|problem at /response/body: template: column 24: dateFormat(): argument 2 must be a format, a string literal such as 'yyyy-MM-dd'
      #|problem at /response/body: template: column 24: dateFormat(): argument 2 must be a format, a string literal such as 'yyyy-MM-dd', not 5
      #|problem at /response/body: template: column 24: dateFormat(): the format "YYYY" has YYYY, the week-numbering year: write yyyy or yy for the calendar year
    ),
  )
}

///|
test "February 29 is a date in leap years only: every fourth year, except centuries not divisible by 400" {
  let leap : @template.Input = {
    ..dated,
    query: [
      ("y2000", "2000-02-29"),
      ("y2024", "2024-02-29T12:00:00Z"),
      ("y1900", "1900-02-29"),
      ("y2100", "2100-02-29T00:00:00Z"),
      ("y2026", "2026-02-29"),
    ],
  }
  inspect(
    ["query.y2000", "query.y2024", "query.y1900", "query.y2100", "query.y2026"]
    .map(date => {
      rendered(
        "${dateFormat(\{date}, 'yyyy-MM-dd EEEE') ?? 'missing'}",
        input=leap,
      )
    })
    .join("\n"),
    content=(
      #|2000-02-29 Tuesday
      #|2024-02-29 Thursday
      #|missing
      #|missing
      #|missing
    ),
  )
  inspect(
    rendered("${dateTimeShift('2100-02-28', 'P1D')}"),
    content="2100-03-01T00:00:00.000Z",
  )
}

///|
test "a date, or what a helper writes, outside the years 0 to 9999 is a render error" {
  let bounds : @template.Input = {
    ..dated,
    body: @utf8.encode(
      (
        #|{ "first": -62167219200000, "last": 253402300799999,
        #|  "before": -62167219200001, "after": 253402300800000, "huge": 1e300 }
      ),
    ),
  }
  let at = (source : String) => rendered(source, input=bounds)
  inspect(
    [
      at(
        "${dateFormat(body.first, 'yyyy-MM-dd')} ${dateFormat(body.last, 'yyyy-MM-dd')}",
      ),
      at("${dateFormat(body.before, 'yyyy')}"),
      at("${dateFormat(body.after, 'yyyy')}"),
      at("${dateFormat(body.huge, 'yyyy')}"),
      at("${dateFormat(body.last, 'yyyy', '+00:01')}"),
      at("${dateFormat(body.first, 'yyyy', '-00:01')}"),
      at("${dateFormat(body.after, 'yyyy', '-09:00')}"),
      at(
        "${dateTimeShift(body.last, 'PT0S')} ${dateTimeShift(body.first, 'PT0S')}",
      ),
      at("${dateTimeShift(body.last, 'PT0.001S') ?? 'x'}"),
      at("${dateTimeShift('9999-12-31', 'P1D')}"),
      at("${dateTimeShift(body.first, '-PT1S')}"),
      at("${dateTimeShift(body.first, '-P1M')}"),
      at("${dateTimeShift(body.first, 'P999999999Y')}"),
      at("${dateTimeShift(body.after, '-P1D')}"),
      rendered_at("${now('yyyy')}", 253_402_300_800_000L),
      rendered_at("${now('yyyy')}", -62_167_219_200_001L),
    ].join("\n"),
    content=(
      #|0000-01-01 9999-12-31
      #|error at /response/body: dateFormat(): the time is outside the years 0 to 9999
      #|error at /response/body: dateFormat(): the time is outside the years 0 to 9999
      #|error at /response/body: dateFormat(): the time is outside the years 0 to 9999
      #|error at /response/body: dateFormat(): the time is outside the years 0 to 9999
      #|error at /response/body: dateFormat(): the time is outside the years 0 to 9999
      #|error at /response/body: dateFormat(): the time is outside the years 0 to 9999
      #|9999-12-31T23:59:59.999Z 0000-01-01T00:00:00.000Z
      #|problem at /response/body: template: column 28: dateTimeShift(): the duration "PT0.001S" has a fraction; write whole amounts, such as 'PT90M'
      #|error at /response/body: dateTimeShift(): the time is outside the years 0 to 9999
      #|error at /response/body: dateTimeShift(): the time is outside the years 0 to 9999
      #|error at /response/body: dateTimeShift(): the time is outside the years 0 to 9999
      #|error at /response/body: dateTimeShift(): the time is outside the years 0 to 9999
      #|error at /response/body: dateTimeShift(): the time is outside the years 0 to 9999
      #|error at /response/body: now(): the time is outside the years 0 to 9999
      #|error at /response/body: now(): the time is outside the years 0 to 9999
    ),
  )
}

///|
test "a literal date, or a literal alternative of a fallback, that is not a date in the years 0 to 9999 is a load error" {
  inspect(
    [
      "${dateFormat('2026-02-30', 'yyyy')}", "${dateFormat(1.5, 'yyyy')}", "${dateFormat(true, 'yyyy')}",
      "${dateFormat(null, 'yyyy')}", "${dateFormat(1e300, 'yyyy')}", "${dateFormat('1769853600000', 'yyyy')}",
      "${dateFormat(query.d ?? 'soon', 'yyyy')}", "${dateTimeShift('yesterday', 'P1D')}",
      "${dateFormat(query.d ?? '2026-01-01', 'yyyy')}", "${dateFormat(1769853600000, 'yyyy')}",
    ]
    .map(source => rendered(source, input=dated))
    .join("\n"),
    content=(
      #|problem at /response/body: template: column 14: dateFormat(): argument 1 must be a date: an RFC 3339 date-time with an offset, a date YYYY-MM-DD or epoch milliseconds, in the years 0 to 9999, not "2026-02-30"
      #|problem at /response/body: template: column 14: dateFormat(): argument 1 must be a date: an RFC 3339 date-time with an offset, a date YYYY-MM-DD or epoch milliseconds, in the years 0 to 9999, not 1.5
      #|problem at /response/body: template: column 14: dateFormat(): argument 1 must be a date: an RFC 3339 date-time with an offset, a date YYYY-MM-DD or epoch milliseconds, in the years 0 to 9999, not true
      #|problem at /response/body: template: column 14: dateFormat(): argument 1 must be a date: an RFC 3339 date-time with an offset, a date YYYY-MM-DD or epoch milliseconds, in the years 0 to 9999, not null
      #|problem at /response/body: template: column 14: dateFormat(): argument 1 must be a date: an RFC 3339 date-time with an offset, a date YYYY-MM-DD or epoch milliseconds, in the years 0 to 9999, not 1e+300
      #|problem at /response/body: template: column 14: dateFormat(): argument 1 must be a date: an RFC 3339 date-time with an offset, a date YYYY-MM-DD or epoch milliseconds, in the years 0 to 9999, not "1769853600000"
      #|problem at /response/body: template: column 14: dateFormat(): argument 1 must be a date: an RFC 3339 date-time with an offset, a date YYYY-MM-DD or epoch milliseconds, in the years 0 to 9999, not "soon"
      #|problem at /response/body: template: column 17: dateTimeShift(): argument 1 must be a date: an RFC 3339 date-time with an offset, a date YYYY-MM-DD or epoch milliseconds, in the years 0 to 9999, not "yesterday"
      #|2026
      #|2026
    ),
  )
}

///|
test "a date written in more than 1 MiB of UTF-8 is a render error" {
  // `T` writes 13 digits at `nine`: each `T ` writes 14 bytes.
  let under = Array::make(74_898, "T ").join("")
  let over = Array::make(74_899, "T ").join("")
  inspect(
    [rendered("${len(now('\{under}'))}"), rendered("${len(now('\{over}'))}")].join(
      "\n",
    ),
    content=(
      #|1048572
      #|error at /response/body: now(): the result takes more than 1 MiB
    ),
  )
}
