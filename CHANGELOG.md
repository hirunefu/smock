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
  the day of the year (`DD`) are load errors. `yyyy` writes the calendar
  year, so the year 0 is `0000`, as in RFC 3339. Offsets are `Z` or
  `±HH:MM`. Shifts take ISO 8601 durations such as `P1M`, and a month
  shift clamps to the end of the month. A date is an RFC 3339 date-time, a
  date `YYYY-MM-DD` or epoch milliseconds; anything else is missing, so
  `??` applies.
- Template helpers for arithmetic: `add`, `subtract`, `multiply`,
  `divide`, `modulo`, `ceil`, `floor`, `round`, `toFixed` and `parseInt`.
  They compute in exact decimal with integers only, so `add(0.1, 0.2)` is
  `0.3` on every target. `divide` rounds half to even at 10 decimal
  places, `round` and `toFixed` round half away from zero, and numbers
  have at most 18 digits before the point and 18 after. A numeric argument
  may be a string that is a JSON number, such as `query.page`. A number
  literal is taken as written, with every digit, even those a 64-bit
  float would lose.
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
  body; `DELETE /v1/mocks/{mock}/variables/{name}` deletes one. A value
  above 1 MiB of compact JSON, the bound each value of a Stub's
  `variables` has, gets 400 `invalid_request`, and a set keeps a number's
  value, not its text. A set counts against the state bound, and one that
  would pass it writes nothing and gets 507 `state_limit_reached`; a
  delete gives the bytes back. A delete of an unset Variable gets 404
  `unknown_variable`. Each set and delete is logged.
- Data buckets: named JSON values that a Mock declares under the new
  top-level `data` of Definition files, with an initial value inline
  (`json`) or in a JSON file of the body-file subdirectory (`jsonFile`).
  Like a JSON Definition file, a `jsonFile` must not repeat a key in one
  object. A bucket with `key` holds an array of objects whose keys,
  strings or integers, are unique by their text, so `42` and `"42"`
  collide; smock checks this when loading. An integer key is judged by
  its 64-bit floating-point value, so `1.0000000000000001` is the key
  `1`. Templates read a bucket of their Stub's Mock as `data.NAME`, with
  steps, `$each` and `len`. A name that is not one of the Mock's buckets
  is an error when loading.
- Session copies of Data buckets. A Session reads a bucket's initial value
  until it first writes to the bucket, which gives it its own copy; reads
  never copy. Requests without a Session share one copy of each bucket.
  Templates read the request's Session's copy, and `smock render` and the
  Admin render operation never read a copy. Copies count
  toward `--state-max-bytes` with Variables: each counts its bucket's
  name, its value's compact JSON and fixed bytes, and its space counts
  once. Initial values do not count.
- Admin API operations on Data buckets, for the calling Session:
  `GET /v1/mocks/{mock}/data` lists a Mock's buckets, with their keys and
  whether the Session holds a copy; `GET /v1/mocks/{mock}/data/{bucket}`
  reads one with the value the Session reads;
  `PUT /v1/mocks/{mock}/data/{bucket}` sets the Session's copy to the JSON
  value in the body; `DELETE /v1/mocks/{mock}/data/{bucket}` drops it, so
  the bucket reads its initial value again. A bucket the Mock does not
  declare gets 404 `unknown_bucket`, and a value that breaks a keyed
  bucket's rules 400 `invalid_data`. A set keeps a number's value, not its
  text, as a Variable's does. A set that would pass the state bound
  writes nothing and gets 507 `state_limit_reached`. Each set and each
  drop of a copy is logged. The `per_replica_state` warning names the
  copies of Data buckets.
- `POST /v1/reset` drops the copies of Data buckets in its scope, which
  give their bytes back to the state bound, and says how many it dropped,
  in `removed.dataBuckets` of its response and its log entry. A reload
  that swaps in new files drops the copies of a Mock that is gone, of a
  bucket the new files no longer declare, and of a bucket whose initial
  value or `key` changed; it keeps the others, so editing an unrelated
  Stub keeps a test's data. Initial values are compared as compact JSON,
  so moving one between `json` and `jsonFile` is no change, and a change
  of `newKey` keeps the copies. The `definitions reloaded` log entry says
  how many copies the reload dropped, in `dataBucketsReset`. Nothing
  expires a copy.
- A Stub's `dataWrites` writes to the Data buckets of its Mock when it
  matches: 1 to 100 writes, applied in order, each `set` (the bucket
  becomes the value), `merge` (a shallow merge of an object into the
  bucket) or `append` (to the array in the bucket), with a value that is
  always a structured template. The values render against the state from
  before the request, after the values of `variables`, and the writes are
  stored with the Variables all at once, or not at all: a value that fails
  to render gives the template failure, a write that cannot be applied
  gives 500 `data write failed`, and writes past the state bound give 507.
  The response sees the data after the writes, and the writes stand
  whatever follows. Only a Session's first write to a bucket copies it.
  An Ephemeral Stub takes `dataWrites` too. When a reload removes a
  write's bucket, or changes it so that the write would no longer load,
  the write gets 500 `data write failed`, checked before any value
  renders. Each Journal entry gains `dataWritten`, the buckets written,
  and `dataError`, why a write failed to apply.
- `dataWrites` writes keyed Data buckets item by item. `set`, `merge` and
  `remove` take the `key` of one item, a text template compared as a key
  text, so `${path[3]}` finds the order whose `id` is `1002` or `"1002"`.
  `append` adds an item at the end. A value's key member may be absent or
  hold the item's key, and the item keeps its stored key value. An item
  that `append` adds without a key gets a new one, as the bucket's
  `newKey` says: one more than the highest integer key, skipping integers
  whose text a string key has, or a version 4 UUID from the request's
  helpers, which `fault.seed` repeats. A key that no item has, a value
  that would break the bucket's rules, and running out of integer keys
  (`no new key`) fail the write, and nothing is written. A literal value
  that already breaks them, such as an item whose key member holds no key
  or a key other than a literal `key`, is an error when loading. A Stub's
  response cannot read a key that its own `append` made.
- `smock render` and the Admin render operation take sample data and show
  the writes a Stub would make. The sample's `data` gives the value of a
  Data bucket of the Stub's Mock in place of its initial value; a name the
  Mock does not declare, or a value that breaks a keyed bucket's rules,
  makes `smock render` exit with status 1 and the Admin render answer 400
  `invalid_data`. The rendering's `dataWrites` lists the writes of the
  Stub's `dataWrites` in order, each with its op, bucket, rendered key and
  rendered value, the new key filled in for an `append` to a keyed bucket,
  and the response reads the data after them. A write that fails to render
  or to apply shows the 500 a request would get, and no write. A rendering
  never reads or writes a Session's copy, and no state bound applies.
- CRUD Stubs: a Stub with `crud` (`bucket`, `path` and optional `headers`)
  in place of `request` and `response` serves a keyed Data bucket as a REST
  resource. `GET <path>` lists the bucket's items, with `X-Total-Count`
  and `X-Filtered-Count`, and `GET <path>/<key>` reads one item, or answers
  404 `no item with this key`. Reads see the Session's copy, or else the
  initial value. Any other method or path shape falls through to later
  Stubs. A CRUD Stub is tried in the usual order, so an earlier Stub can
  take over one of its requests. `crud.headers`, such as CORS headers, go
  on every answer, and `fault` works as on any Stub. An Ephemeral Stub can
  be a CRUD Stub. Each Journal entry gains `crud`, the operation and its
  key.
- CRUD Stubs write: `POST <path>` creates an item and answers 201 with it
  and its `Location`, `PUT <path>/<key>` replaces the item, `PATCH
  <path>/<key>` merges the body into it shallowly, and `DELETE
  <path>/<key>` removes it and answers the removed item. Each is one write
  by key, as `dataWrites` makes, to the Session's copy, made at the match
  decision before any delay, all or nothing, within the state bound. The
  body must be a JSON object, whatever its Content-Type (400 `body is not
  a JSON object`). A create without the key member gets a new key, added
  last; a key that is not one is 400 `invalid key`, and a taken one 409
  `key already exists`. A replace or update keeps the item's key, and a
  body that holds another is 400 `key does not match the path`. A missing
  item is 404, no integer key left 500 `no new key`, and the state bound
  507, a delete's included. A connection Fault replaces the answer, but
  not the write.
- List queries: a CRUD Stub's list reads its query in smock's own syntax.
  A parameter filters on the item member of its name, as `find` compares,
  and a repeated name holds when any of its values does. `$sort=a,-b`
  sorts by members, by type first and then by value, with strings by
  Unicode code point; absent members, objects and arrays go last, and the
  sort is stable. `$offset` and `$limit` page the list. `X-Filtered-Count`
  counts the items that pass the filters, before paging, and the body
  stays a plain array. `$$name` filters on the member `$name`, and any
  other name that starts with `$`, such as OData's `$top`, is 400
  `invalid query parameter`, without the two counts, as are malformed or
  repeated `$sort`, `$offset` and `$limit`. A client's own parameters,
  such as `page`, are filters too, so its list comes back `[]`.
- A CRUD Stub can be the Near miss of a request that no Stub matches. It
  counts two conditions: `path` fails when the request path is neither its
  list path nor an item path, and `method` when the Stub does not serve
  the method at the path's shape, or at either shape when `path` fails.
  The Near miss expects `{"crud": "<path>"}` or `{"crud": [<methods>]}`,
  and the header keeps its form, such as `Smock-Near-Miss: orders;
  failed=method`.
- `smock check` warns about CRUD Stubs in the cases it can prove: an
  earlier CRUD Stub hides a later Stub whose method and exact path it
  serves, whatever that Stub's other conditions or `requires`, or a later
  CRUD Stub with the same path; a Stub with no request conditions and no
  `requires` hides a later CRUD Stub. A partial overlap gets no warning.
- `smock render` and the Admin render operation render a CRUD Stub: the
  answer its operation would give to the sample, from the sample's data or
  else the initial value, failures and list queries included, with a new
  `uuid` key drawn from the seed. Its write shows in `dataWrites` as the op
  that makes the same write, `append` for a create, `set` for a replace,
  `merge` for an update and `remove` for a delete, and not at all when it
  fails. A sample whose method and path fit no operation of the Stub, and
  a `--response` index, make `smock render` exit with status 1 and the
  Admin render answer 400 `invalid_request`.
- docs/migrating-from-mockoon.md maps Mockoon's helpers, `RANDOM` routes,
  global variables, Range requests, dates, cookies and environment
  variables onto smock, with each difference called out. It also maps
  data buckets, CRUD routes and their list parameters, the `data` and
  `dataRaw` helpers, `setData` and the purge of data buckets onto Data
  buckets, CRUD Stubs, list queries and `dataWrites`, and its worked
  example serves its orders from a Data bucket with a CRUD Stub.
- `smock import-openapi <document> --mock <name> --output <file>` converts
  an OpenAPI 3.0, 3.1 or 3.2 document into one Definition file, once.
  smock never reads OpenAPI when it serves. `--hosts` gives the Mock its
  Hosts, and `--declare-mock off` writes only Stubs, for a Mock declared by
  hand in another file; the document's `servers` never become Hosts. Parts
  that it does not import, such as callbacks and webhooks, are left out
  with a warning. See [docs/importing-openapi.md](docs/importing-openapi.md).
  The Mockoon migration guide points there too: an environment that
  Mockoon imported from an OpenAPI document can be imported into smock from
  the same document.
- Each imported operation, 3.2's `query` and `additionalOperations`
  included, becomes Stubs that match its method and its path, under the
  path of its server URL, so the mock answers where the real service does;
  `--base-path` replaces that prefix. A path with parameters, such as
  `/pets/{petId}`, becomes a pattern in which each parameter matches one
  segment, and concrete paths come before templated ones. The main
  response answers by default. Every other response has a Stub that a
  request selects with `Smock-Status: <key>`, such as `404`, and every
  further named example one that `Smock-Example: <name>` selects. A test
  that reaches the mock through its system under test adds an Ephemeral Stub
  for its Session instead, as the guide shows.
- Imported bodies come from a media type's `examples`, then its `example`,
  then one fixed sample of its schema, written in the file as `json` or
  `body`, with the media type as the Content-Type. Samples follow formats,
  number bounds, `allOf`, `oneOf` and `anyOf`, and `$ref`, recursive schemas
  included. Nothing is random and nothing is templated, and number bounds
  use exact decimal arithmetic on the shortest decimal text of each bound,
  so every platform writes the same digits. A sample nests at most 32
  levels, one above 64 KiB is cut to its required parts, and a body above
  1 MiB is left empty, with a warning.
  The headers a response documents are written too, with their example or a
  sample of their schema; a header with neither is left out, with a
  warning.
- `smock import-openapi` reads YAML documents as YAML 1.2, as OpenAPI
  recommends, so `200:` is the key `"200"` and a date is a string; anchors
  and aliases stay errors. It follows a `$ref` where OpenAPI allows one,
  within the document and into other files under `--ref-dir`, by default the
  document's directory, so a downloaded document cannot copy a secret into a
  committed file. At most 1,000 documents and 64 MiB are read. A URL is an
  error that suggests bundling the document into one file first.
- The import writes YAML or JSON, as the name of `--output` says. A YAML
  file starts with a comment that names the document and the flags whose
  value is not the default, and says not to edit the file, and each Stub
  has one that maps it back to its operation. An existing file is replaced
  only with `--overwrite on`, through a temporary file and a rename, so a
  smock that watches the directory never loads half a file. The guide
  shows how to keep hand changes in another file, and how CI can check
  that the file is current.
- `write` in the `smock/yaml` module turns a JSON tree into a YAML
  document, with comments, that the module's own parser reads back as the
  same tree. A string is quoted only when it would not read back as the
  same string. The OpenAPI import writes YAML Definition files with it.
- `parse` in the `smock/yaml` module has a mode for OpenAPI documents,
  `openapi=true`. It types plain values by the YAML 1.2 core schema, as
  OpenAPI asks: `200:` is the key `"200"`, `2020-01-01` and `yes` are
  strings, `007` is the number 7, and `~` is null. It also accepts block
  scalar indentation indicators such as `|2`. Definition files keep the
  safe subset, unchanged. The OpenAPI import reads YAML documents with it.

### Changed

- A loop variable named `cookie`, `env` or `vars` now fails to load, since
  `cookie`, `env` and `vars` are template roots. No valid file changes
  meaning: rename the loop variable. The Definition file format is still
  version 1.
- A loop variable named `data` now fails to load, since `data` is the
  template root of Data buckets. Rename the loop variable. No other valid
  file changes meaning, and the format is still version 1.
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
