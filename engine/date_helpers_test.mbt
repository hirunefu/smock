// Seam 1 tests of the date helpers, `now(format)`, `dateFormat` and
// `dateTimeShift`: the worked example of their ticket, dates from the
// request formatted and shifted, the render errors they give, with the
// JSON Pointer of the field, and the load errors of their literals.

///|
/// The worked example: today's date, and a due date a month on, written at
/// +09:00.
let due_date_example : (String, String) = (
  "dates.yaml",
  (
    #|mocks:
    #|  - name: dates
    #|stubs:
    #|  - id: due
    #|    mock: dates
    #|    response:
    #|      status: 200
    #|      template: true
    #|      json:
    #|        today: ${now('yyyy-MM-dd')}
    #|        due: ${dateFormat(dateTimeShift(now(), 'P1M'), 'yyyy-MM-dd', '+09:00')}
  ),
)

///|
test "worked example: a month after January 31 is the last day of February" {
  let h = harness([due_date_example])
  h.now = 1_769_853_600_000L // 2026-01-31T10:00:00Z
  inspect(
    response(h.send("GET", "/")),
    content=(
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: dates; via=default
      #|{"today":"2026-01-31","due":"2026-02-28"}
    ),
  )
}

///|
test "a date from the request is formatted at an offset and shifted; a date that is not one is missing, so ?? applies" {
  let h = one_response(
    (
      #|{ "status": 200, "template": true,
      #|  "json": { "day": "${dateFormat(query.since, 'EEEE d MMMM yyyy, h:mm a XXX', '+09:00')}",
      #|            "expires": "${dateTimeShift(body.issuedAt, 'PT90M')}",
      #|            "renewal": "${dateFormat(dateTimeShift(body.issuedAt, '-P1Y'), 'yyyy-MM-dd')}",
      #|            "seen": "${dateFormat(number(query.ts ?? 0), 'T')}",
      #|            "until": "${dateFormat(query.until, 'yyyy-MM-dd') ?? 'open'}" } }
    ),
  )
  inspect(
    [
      h.body(
        "/?since=2026-03-05T14:07:08Z&ts=1769853600000",
        body="{\"issuedAt\":\"2024-02-29T23:30:00-01:00\"}",
      ),
      h.body(
        "/?since=2026-03-05&until=1769853600000",
        body="{\"issuedAt\":1769853600000}",
      ),
      h.body("/?since=2026-03-05", body="{\"issuedAt\":\"2026-01-31 10:00Z\"}"),
      h.body("/?since=2026-03-05", body="{\"issuedAt\":253402300799999}"),
    ].join("\n"),
    content=(
      #|{"day":"Thursday 5 March 2026, 11:07 PM +09:00","expires":"2024-03-01T02:00:00.000Z","renewal":"2023-03-01","seen":"1769853600000","until":"open"}
      #|{"day":"Thursday 5 March 2026, 9:00 AM +09:00","expires":"2026-01-31T11:30:00.000Z","renewal":"2025-01-31","seen":"0","until":"open"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/expires","message":"dateTimeShift(body.issuedAt, 'PT90M') is missing"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/expires","message":"dateTimeShift(): the time is outside the years 0 to 9999"}
    ),
  )
}

///|
test "a bad date format, offset, duration or literal date is reported when loading, with its message" {
  let bodies = [
    "${now('YYYY-MM-dd')}", "${now('yyyy-MM-DD')}", "${now('yyyy-MM-dd q')}", "${now('yyy')}",
    "${now(\"'at\")}", "${now(query.f)}", "${dateFormat(query.d)}", "${dateFormat(query.d, query.f)}",
    "${dateFormat(query.d, 'yyyy', '+9')}", "${dateFormat(query.d, 'yyyy', 'Asia/Tokyo')}",
    "${dateFormat('2026-02-30', 'yyyy')}", "${dateFormat(query.d ?? 1.5, 'yyyy')}",
    "${dateTimeShift(query.d, 'P2W')}", "${dateTimeShift(query.d, 'PT1.5H')}", "${dateTimeShift(query.d, 'P1234567890D')}",
    "${dateTimeShift(query.d, '1 month')}", "${dateTimeShift(query.d, query.p)}",
    "${dateTimeShift(query.d)}",
  ]
  inspect(
    template_problems(
      bodies
      .mapi((i, body) => templated(i, "body: \{Json::string(body).stringify()}"))
      .join(""),
    ),
    content=(
      #|m.yaml: /stubs/0/response/body: template: column 7: now(): the format "YYYY-MM-dd" has YYYY, the week-numbering year: write yyyy or yy for the calendar year
      #|m.yaml: /stubs/1/response/body: template: column 7: now(): the format "yyyy-MM-DD" has DD, the day of the year: write dd or d for the day of the month
      #|m.yaml: /stubs/2/response/body: template: column 7: now(): the format "yyyy-MM-dd q" has q, which is not a token; quote letters to write them as they are, as in 'at'
      #|m.yaml: /stubs/3/response/body: template: column 7: now(): the format "yyy" has yyy, but y is written yyyy or yy
      #|m.yaml: /stubs/4/response/body: template: column 7: now(): the format "'at" has a quote that is not closed; write '' for a quote
      #|m.yaml: /stubs/5/response/body: template: column 7: now(): argument 1 must be a format, a string literal such as 'yyyy-MM-dd', or seconds, an integer literal from -9007199254740991 to 9007199254740991
      #|m.yaml: /stubs/6/response/body: template: column 3: dateFormat() takes 2 or 3 arguments, not 1
      #|m.yaml: /stubs/7/response/body: template: column 23: dateFormat(): argument 2 must be a format, a string literal such as 'yyyy-MM-dd'
      #|m.yaml: /stubs/8/response/body: template: column 31: dateFormat(): argument 3 must be an offset, a string literal: 'Z', or '+HH:MM' or '-HH:MM' with HH up to 23 and MM up to 59, not "+9"
      #|m.yaml: /stubs/9/response/body: template: column 31: dateFormat(): argument 3 must be an offset, a string literal: 'Z', or '+HH:MM' or '-HH:MM' with HH up to 23 and MM up to 59, not "Asia/Tokyo"
      #|m.yaml: /stubs/10/response/body: template: column 14: dateFormat(): argument 1 must be a date: an RFC 3339 date-time with an offset, a date YYYY-MM-DD or epoch milliseconds, in the years 0 to 9999, not "2026-02-30"
      #|m.yaml: /stubs/11/response/body: template: column 14: dateFormat(): argument 1 must be a date: an RFC 3339 date-time with an offset, a date YYYY-MM-DD or epoch milliseconds, in the years 0 to 9999, not 1.5
      #|m.yaml: /stubs/12/response/body: template: column 26: dateTimeShift(): the duration "P2W" has weeks, which a shift does not take; write days, such as 'P14D'
      #|m.yaml: /stubs/13/response/body: template: column 26: dateTimeShift(): the duration "PT1.5H" has a fraction; write whole amounts, such as 'PT90M'
      #|m.yaml: /stubs/14/response/body: template: column 26: dateTimeShift(): the duration "P1234567890D" has an amount of more than 9 digits
      #|m.yaml: /stubs/15/response/body: template: column 26: dateTimeShift(): argument 2 must be a duration, a string literal such as 'P1M', '-P2D' or 'PT90M', not "1 month"
      #|m.yaml: /stubs/16/response/body: template: column 26: dateTimeShift(): argument 2 must be a duration, a string literal such as 'P1M', '-P2D' or 'PT90M'
      #|m.yaml: /stubs/17/response/body: template: column 3: dateTimeShift() takes 2 arguments, not 1
    ),
  )
}
