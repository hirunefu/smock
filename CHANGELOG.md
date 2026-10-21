# Changelog

All notable changes to smock are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The notes
of each GitHub release include its section
([docs/releasing.md](docs/releasing.md#every-release-after)).

## [Unreleased]

### Added

- `cookie.NAME` in templates reads a cookie as cookie conditions read it,
  from every `Cookie` field, with quotes kept and nothing percent-decoded.
  It is the first value of the cookie, and `$each` over it walks every
  value.
- Template helpers for text: `len`, `concat`, `padStart`, `padEnd`,
  `substr`, `indexOf`, `includes`, `replace`, `replaceAll`, `split` and
  `join`. Lengths and positions count Unicode code points. A text argument
  may be a number or a boolean, taken as its text. `replace` and
  `replaceAll` take the replacement literally. `split` gives an array that
  `$each` can walk, and `join` turns an array back into text.
- Template helpers `uppercase`, `lowercase` and `trim`, from the data of
  Unicode 18.0.0, built in: simple case mapping, one code point to one and
  with no locale (`ß` stays `ß`), and White_Space removed at both ends.
- Template helpers for encodings: `base64`, `base64url`, `base64Decode`,
  `base64urlDecode`, `urlEncode` and `urlDecode`. The decoders refuse
  characters outside their alphabet, wrong padding and malformed escapes,
  and turn bytes that are not UTF-8 into U+FFFD. `urlEncode` follows
  RFC 3986, so a space is `%20`.
- Template helpers `jwtPayload` and `jwtHeader` give the payload or the
  header of a JWT as an object, read with steps, such as
  `${jwtPayload(header.authorization).sub ?? 'anonymous'}`. A leading
  `Bearer` is removed. They only decode: no signature is ever checked. A
  malformed token is missing, so `??` applies.
- Template helpers for dates: `now(format)`, `dateFormat(date, format,
  offset)` and `dateTimeShift(date, duration)`. Formats use date-fns
  tokens, with English names only; the week-numbering year (`YYYY`) and
  the day of the year (`DD`) are load errors. Offsets are `Z` or `±HH:MM`.
  Shifts take ISO 8601 durations such as `P1M`, and a month shift clamps
  to the end of the month. A date is an RFC 3339 date-time, a date
  `YYYY-MM-DD` or epoch milliseconds; anything else is missing, so `??`
  applies.
- Template helpers for arithmetic: `add`, `subtract`, `multiply`,
  `divide`, `modulo`, `ceil`, `floor`, `round`, `toFixed` and `parseInt`.
  They compute in exact decimal with integers only, so `add(0.1, 0.2)` is
  `0.3` on every target. `divide` rounds half to even at 10 decimal
  places, `round` and `toFixed` round half away from zero, and numbers
  have at most 18 digits before the point and 18 after. A numeric argument
  may be a string that is a JSON number, such as `query.page`.
- Template helper `find(array, member, value)` gives the first element of
  an array that is an object whose member meets a value. The value is
  taken as text, `null` included. A member meets it when it is a string
  equal to that text, a number of equal value as `json` conditions compare
  numbers (`12.50` meets `12.5`), or `true`, `false` or `null` by those
  words. So `find(body.orders, 'id', path[1])` finds the order `1004`
  whether its `id` is a number or a string. When no element meets the
  value, the call is missing, so `??` applies.
- A helper call can be followed by steps, as a reference can:
  `${range(1, 3)[1]}` gives `2`.
- The bounds of `range(a, b)` can be any expression that gives an integer,
  such as `len(body.items)`.
- A helper's result above 1 MiB is a render error, found before the
  result is built.
- `--template-env` (`SMOCK_TEMPLATE_ENV`) on `smock serve`, `smock check`
  and `smock render` lists, separated by commas, the environment variables
  templates may read. Their values are read once, at startup, and every
  load, reload and Ephemeral Stub uses them. A name that starts with
  `SMOCK_` cannot be listed.
- The template root `env.NAME` gives the value of a listed variable as a
  string, and is missing when it is unset. A name that is not listed is an
  error when loading.
- `responses`: a Stub can give 1 to 100 responses with integer weights,
  from 1 to 1,000,000, instead of `response`. Each matched request gets
  one of them, picked with the probability of its weight over the sum of
  the weights, so the status can vary. The pick draws from the request's
  one random draw, so `fault.seed` and `--seed` replay it, and it leaves a
  seed's Fault decisions and helper output as they are. Ephemeral Stubs
  take `responses` with inline bodies.
- Journal entries record `responseIndex`, the index of the response a
  request got. It is null for a Stub with `response`, for a request no
  Stub matched, and when no response was picked, because a value of the
  Stub's `variables` failed to render or the state bound refused its
  writes.
- `smock render` and the Admin render operation show `responseIndex`, and
  render a given response with `--response <i>` and the `response` query
  parameter.
- Variables: named JSON values kept per Mock and Session. A Stub's
  `variables` write them when it matches, before its response is built,
  and templates read them as `vars.NAME`, so a POST can store what a later
  GET returns. Each value is a template, rendered against the Variables as
  they were before the request; a value that fails to render writes none
  of them. Ephemeral Stubs take `variables` too.
- Journal entries record `variablesWritten`, the names of the Variables a
  request wrote.
- `POST /v1/reset` clears the Variables in its scope and says how many it
  cleared, in `removed.variables` of its response and its log entry. A
  reload keeps Variables, except those of a Mock the new files no longer
  declare. The `per_replica_state` warning names Variables too.
- `smock render` and the Admin render operation show `variables`, the
  values a Stub would write, and take the Variables templates read from
  the sample's optional `vars` object, never from the live Variables. The
  response sees the sample's `vars` with the Stub's values written over
  them. A rendering writes nothing, so it stays repeatable.
- Range requests. An untemplated body file of a 200 answers a GET for a
  single byte range with 206 Partial Content and `Content-Range`, or with
  416 and `Content-Range: bytes */<length>` when the range starts past the
  end. Such a 200, to GET and to HEAD, and every 206 carry
  `Accept-Ranges: bytes`. Several ranges, more than one `Range` field, a
  malformed field, another unit, any `If-Range` and an empty file get the
  whole body with 200. A Stub that gives status 206, `Content-Range` or
  `Accept-Ranges` itself is left alone. A `partial` Fault cuts the range
  in half. `smock render` and the Admin render operation apply the rule to
  the sample's `Range` header.
- `--state-max-bytes` (`SMOCK_STATE_MAX_BYTES`) bounds, in bytes, the
  per-Session state of the whole process, across every Mock and Session.
  By default it is an eighth of smock's memory limit, at least 1 MiB and
  at most 64 MiB, as ADR 0004's rule gives the Journal a quarter; smock
  logs the bound at startup. Each space of a Mock and a Session counts its
  Mock name and Session key, and each Variable its name and its value's
  compact JSON, with fixed bytes for each space, Variable and JSON value.
  A request whose writes would pass the bound writes nothing, picks no
  response and gets 507 `state limit reached`.
- The metrics `smock_state_bytes`, the bytes the state bound counts, and
  `smock_state_writes_refused_total`, the writes it refused, from requests
  and Admin API sets.
- Admin API operations on the calling Session's Variables of a Mock:
  `GET /v1/mocks/{mock}/variables` lists them by name, with their values;
  `PUT /v1/mocks/{mock}/variables/{name}` sets one to the JSON value in the
  body; `DELETE /v1/mocks/{mock}/variables/{name}` deletes one. A set
  counts against the state bound, and one that would pass it writes
  nothing and gets 507 `state_limit_reached`; a delete gives the bytes
  back. A delete of an unset Variable gets 404 `unknown_variable`. Each set
  and delete is logged.
- docs/migrating-from-mockoon.md maps Mockoon's helpers, `RANDOM` routes,
  global variables, Range requests, dates, cookies and environment
  variables onto smock, with each difference called out.

### Changed

- A loop variable named `cookie`, `env` or `vars` now fails to load, since
  `cookie`, `env` and `vars` are template roots. No valid file changes
  meaning: rename the loop variable. The Definition file format is still
  version 1.
- A 200 from an untemplated body file now carries `Accept-Ranges: bytes`,
  and a GET with a `Range` field gets the range it asks for. To keep
  sending the whole body, give the response an `Accept-Ranges` header of
  its own, such as `none`.

## [0.2.0] - 2026-10-21

### Added

- Operators in request conditions. `$not` negates a condition, and
  `$exists` asks whether a query parameter, header, cookie, form field or
  XML path is present. Inside `json` conditions, `$not` and `$exists` work
  on any value, `$includes` matches an array with an element that meets
  its condition, and `$$name` writes a key that starts with `$`.
- `cookies` conditions match the cookies of the request by name, from
  every `Cookie` field.
- `form` body conditions match the fields of an
  `application/x-www-form-urlencoded` body by name. They hold only when the
  Content-Type says the body is a form.
- `xml` body conditions match the values at simple paths into an XML body,
  such as `/Envelope/Body/GetUser/id` or `/order/item/@sku`. A body that is
  not well-formed XML, or that has a DOCTYPE, fails them.
- The `smock/xml` module, the XML parser and paths behind `xml` conditions.
  It does no I/O and depends only on `moonbitlang/core`.
- The Near miss names the new conditions `cookie:<name>`, `form:<name>` and
  `xml:<path>`, and shows operators as the Stub writes them. Journal
  filters take `$not` and `$exists` for headers.

### Changed

- Two kinds of `json` condition written for smock 0.1 now mean something
  else. The Definition file format is still version 1.
  - An object whose only key is `$not`, `$exists` or `$includes` was
    literal JSON, and is now an operator.
  - A key that starts with `$$`, such as `$$id`, matched that key as
    written, and now matches it with one `$` less, `$id`.

  Any other key that starts with `$` in a `json` condition is now an
  error, so a file with one fails to load rather than change its meaning:
  write the key with `$$`.
- The Journal bounds the form and XML values that an entry's Near miss
  keeps. They are kept in order until their total reaches
  `--journal-body-limit`, each counting its bytes and 32 bytes more; the
  last one kept is cut, and the rest are dropped. The 32 bytes per value
  also count toward `--journal-max-bytes`.

## [0.1.0] - 2026-10-19

- The first public release.

[Unreleased]: https://github.com/hirunefu/smock/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/hirunefu/smock/releases/tag/v0.2.0
[0.1.0]: https://github.com/hirunefu/smock/releases/tag/v0.1.0
