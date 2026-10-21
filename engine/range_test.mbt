// Seam 1 tests of Range requests: a single byte range of an untemplated
// body file of a 200, answered with 206 or 416, the cases that get the
// whole body, `Accept-Ranges`, the Stubs left alone, Faults and the Journal,
// `responses`, and rendering.

///|
/// Mock `media` with `GET /letters`, which answers 200 with the 26 letters
/// of `letters.txt`, a body file, and a Content-Type of its own.
let media : String =
  #|{ "mocks": [{ "name": "media" }],
  #|  "stubs": [
  #|    { "id": "letters", "mock": "media",
  #|      "request": { "method": "GET", "path": "/letters" },
  #|      "response": { "status": 200, "headers": { "Content-Type": "text/plain" },
  #|        "bodyFile": "letters.txt" } } ] }

///|
/// The body files of `media`.
let media_files : Array[(String, Bytes)] = [
  ("letters.txt", b"abcdefghijklmnopqrstuvwxyz"),
]

///|
test "a GET with one satisfiable byte range gets 206, Content-Range, Accept-Ranges and those bytes" {
  let h = harness([("media.json", media)], body_files=media_files)
  inspect(
    response(h.send("GET", "/letters", headers=[("Range", "bytes=0-4")])),
    content=(
      #|206
      #|Content-Type: text/plain
      #|Content-Range: bytes 0-4/26
      #|Accept-Ranges: bytes
      #|Smock-Mock: media; via=default
      #|abcde
    ),
  )
}

///|
test "a range that starts at or past the end gets 416, Content-Range with the length alone, no Accept-Ranges and no body" {
  let h = harness([("media.json", media)], body_files=media_files)
  inspect(
    response(h.send("GET", "/letters", headers=[("Range", "bytes=26-")])) +
    "\n---\n" +
    response(h.send("GET", "/letters", headers=[("Range", "bytes=30-40")])),
    content=(
      #|416
      #|Content-Type: text/plain
      #|Content-Range: bytes */26
      #|Smock-Mock: media; via=default
      #|
      #|---
      #|416
      #|Content-Type: text/plain
      #|Content-Range: bytes */26
      #|Smock-Mock: media; via=default
      #|
    ),
  )
}

///|
/// What `GET /letters` with the `Range` field `range` gets: the status, the
/// Content-Range value, `-` without one, and the body. A tab in `range` is
/// shown as `\t`.
fn letters_with(h : Harness, range : String) -> String {
  let plan = h.send("GET", "/letters", headers=[("Range", range)]).plan
  let mut content_range = "-"
  for header in plan.headers {
    if header.0 == "Content-Range" {
      content_range = header.1
    }
  }
  guard plan.body is Bytes(body) else { abort("not a byte body") }
  let shown = range.replace_all(old="\t", new="\\t")
  "\{shown}: \{plan.status} \{content_range} \{@utf8.decode_lossy(body)}"
}

///|
test "first-last, first- and -suffix are taken, a last position at or past the end means the end, and a suffix longer than the file selects it whole" {
  let h = harness([("media.json", media)], body_files=media_files)
  let ranges = [
    "bytes=0-0", "bytes=3-7", "bytes=25-25", "bytes=20-", "bytes=20-25", "bytes=20-26",
    "bytes=20-1000", "bytes=-3", "bytes=-26", "bytes=-27", "bytes=0000-0002",
    // Empty list elements are ignored.
     "bytes=,0-1", "bytes=0-1,", "bytes=, 0-1", "bytes=0-1 ,", "bytes=0-1, ,\t,",
  ]
  inspect(
    ranges.map(range => letters_with(h, range)).join("\n"),
    content=(
      #|bytes=0-0: 206 bytes 0-0/26 a
      #|bytes=3-7: 206 bytes 3-7/26 defgh
      #|bytes=25-25: 206 bytes 25-25/26 z
      #|bytes=20-: 206 bytes 20-25/26 uvwxyz
      #|bytes=20-25: 206 bytes 20-25/26 uvwxyz
      #|bytes=20-26: 206 bytes 20-25/26 uvwxyz
      #|bytes=20-1000: 206 bytes 20-25/26 uvwxyz
      #|bytes=-3: 206 bytes 23-25/26 xyz
      #|bytes=-26: 206 bytes 0-25/26 abcdefghijklmnopqrstuvwxyz
      #|bytes=-27: 206 bytes 0-25/26 abcdefghijklmnopqrstuvwxyz
      #|bytes=0000-0002: 206 bytes 0-2/26 abc
      #|bytes=,0-1: 206 bytes 0-1/26 ab
      #|bytes=0-1,: 206 bytes 0-1/26 ab
      #|bytes=, 0-1: 206 bytes 0-1/26 ab
      #|bytes=0-1 ,: 206 bytes 0-1/26 ab
      #|bytes=0-1, ,\t,: 206 bytes 0-1/26 ab
    ),
  )
}

///|
test "a suffix of 0 gets 416, and the unit is compared case-insensitively" {
  let h = harness([("media.json", media)], body_files=media_files)
  let ranges = ["bytes=-0", "bytes=-000", "BYTES=0-1", "Bytes=-2"]
  inspect(
    ranges.map(range => letters_with(h, range)).join("\n"),
    content=(
      #|bytes=-0: 416 bytes */26 
      #|bytes=-000: 416 bytes */26 
      #|BYTES=0-1: 206 bytes 0-1/26 ab
      #|Bytes=-2: 206 bytes 24-25/26 yz
    ),
  )
}

///|
test "several ranges, another unit and a malformed field get the whole body with 200 and Accept-Ranges" {
  let h = harness([("media.json", media)], body_files=media_files)
  let ranges = [
    // Several ranges, even when they overlap or one is empty.
    "bytes=0-1,3-4", "bytes=0-1, 3-4", "bytes=0-1,0-1", "bytes=-1,0-",
    // Another unit.
     "items=0-1", "bytesx=0-1", "byte=0-1",
    // A last position below the first.
     "bytes=5-4", "bytes=30-4",
    // Not the grammar of a byte range.
     "", "bytes", "bytes=", "bytes=-", "bytes=a-b", "bytes=1-a", "bytes=+1-2", "bytes=1--2",
    "bytes=1-2-", "bytes = 0-1", "bytes= 0-1", "bytes=0 -1", "bytes=0x1-2", "bytes=0-1 ",
    "bytes=0.5-1", "bytes=,", "=0-1",
  ]
  inspect(
    ranges.map(range => letters_with(h, range)).join("\n"),
    content=(
      #|bytes=0-1,3-4: 200 - abcdefghijklmnopqrstuvwxyz
      #|bytes=0-1, 3-4: 200 - abcdefghijklmnopqrstuvwxyz
      #|bytes=0-1,0-1: 200 - abcdefghijklmnopqrstuvwxyz
      #|bytes=-1,0-: 200 - abcdefghijklmnopqrstuvwxyz
      #|items=0-1: 200 - abcdefghijklmnopqrstuvwxyz
      #|bytesx=0-1: 200 - abcdefghijklmnopqrstuvwxyz
      #|byte=0-1: 200 - abcdefghijklmnopqrstuvwxyz
      #|bytes=5-4: 200 - abcdefghijklmnopqrstuvwxyz
      #|bytes=30-4: 200 - abcdefghijklmnopqrstuvwxyz
      #|: 200 - abcdefghijklmnopqrstuvwxyz
      #|bytes: 200 - abcdefghijklmnopqrstuvwxyz
      #|bytes=: 200 - abcdefghijklmnopqrstuvwxyz
      #|bytes=-: 200 - abcdefghijklmnopqrstuvwxyz
      #|bytes=a-b: 200 - abcdefghijklmnopqrstuvwxyz
      #|bytes=1-a: 200 - abcdefghijklmnopqrstuvwxyz
      #|bytes=+1-2: 200 - abcdefghijklmnopqrstuvwxyz
      #|bytes=1--2: 200 - abcdefghijklmnopqrstuvwxyz
      #|bytes=1-2-: 200 - abcdefghijklmnopqrstuvwxyz
      #|bytes = 0-1: 200 - abcdefghijklmnopqrstuvwxyz
      #|bytes= 0-1: 200 - abcdefghijklmnopqrstuvwxyz
      #|bytes=0 -1: 200 - abcdefghijklmnopqrstuvwxyz
      #|bytes=0x1-2: 200 - abcdefghijklmnopqrstuvwxyz
      #|bytes=0-1 : 200 - abcdefghijklmnopqrstuvwxyz
      #|bytes=0.5-1: 200 - abcdefghijklmnopqrstuvwxyz
      #|bytes=,: 200 - abcdefghijklmnopqrstuvwxyz
      #|=0-1: 200 - abcdefghijklmnopqrstuvwxyz
    ),
  )
}

///|
test "more than one Range field, or any If-Range, gets the whole body with 200 and Accept-Ranges" {
  let h = harness([("media.json", media)], body_files=media_files)
  let send = (headers : Array[(String, String)]) => {
    response(h.send("GET", "/letters", headers~))
  }
  inspect(
    [
      send([("Range", "bytes=0-1"), ("Range", "bytes=0-1")]),
      send([("Range", "bytes=0-1"), ("range", "")]),
      send([("Range", "bytes=0-1"), ("If-Range", "\"v1\"")]),
      send([
        ("if-range", "Wed, 21 Oct 2026 07:28:00 GMT"),
        ("Range", "bytes=0-1"),
      ]),
      send([("If-Range", "")]),
    ].join("---\n"),
    content=(
      #|200
      #|Content-Type: text/plain
      #|Accept-Ranges: bytes
      #|Smock-Mock: media; via=default
      #|abcdefghijklmnopqrstuvwxyz---
      #|200
      #|Content-Type: text/plain
      #|Accept-Ranges: bytes
      #|Smock-Mock: media; via=default
      #|abcdefghijklmnopqrstuvwxyz---
      #|200
      #|Content-Type: text/plain
      #|Accept-Ranges: bytes
      #|Smock-Mock: media; via=default
      #|abcdefghijklmnopqrstuvwxyz---
      #|200
      #|Content-Type: text/plain
      #|Accept-Ranges: bytes
      #|Smock-Mock: media; via=default
      #|abcdefghijklmnopqrstuvwxyz---
      #|200
      #|Content-Type: text/plain
      #|Accept-Ranges: bytes
      #|Smock-Mock: media; via=default
      #|abcdefghijklmnopqrstuvwxyz
    ),
  )
}

///|
/// Mock `media` with Stubs without a method: `/any` answers 200 from
/// `letters.txt`, and `/empty` 200 from an empty body file.
let any_method : String =
  #|{ "mocks": [{ "name": "media" }],
  #|  "stubs": [
  #|    { "id": "any", "mock": "media", "request": { "path": "/any" },
  #|      "response": { "status": 200, "bodyFile": "letters.txt" } },
  #|    { "id": "empty", "mock": "media", "request": { "path": "/empty" },
  #|      "response": { "status": 200, "bodyFile": "empty.txt" } } ] }

///|
test "Accept-Ranges is on a 200 to GET and to HEAD, which ignores Range, but not to other methods" {
  let h = harness([("any.json", any_method)], body_files=[
    ("letters.txt", b"abcdefghijklmnopqrstuvwxyz"),
    ("empty.txt", b""),
  ])
  inspect(
    [
      response(h.send("GET", "/any")),
      response(h.send("HEAD", "/any", headers=[("Range", "bytes=0-1")])),
      response(h.send("POST", "/any", headers=[("Range", "bytes=0-1")])),
      response(h.send("DELETE", "/any")),
      response(h.send("get", "/any", headers=[("Range", "bytes=0-1")])),
    ].join("---\n"),
    content=(
      #|200
      #|Accept-Ranges: bytes
      #|Smock-Mock: media; via=default
      #|abcdefghijklmnopqrstuvwxyz---
      #|200
      #|Accept-Ranges: bytes
      #|Smock-Mock: media; via=default
      #|abcdefghijklmnopqrstuvwxyz---
      #|200
      #|Smock-Mock: media; via=default
      #|abcdefghijklmnopqrstuvwxyz---
      #|200
      #|Smock-Mock: media; via=default
      #|abcdefghijklmnopqrstuvwxyz---
      #|200
      #|Smock-Mock: media; via=default
      #|abcdefghijklmnopqrstuvwxyz
    ),
  )
}

///|
test "a Stub with method GET still does not answer HEAD" {
  let h = harness([("media.json", media)], body_files=media_files)
  let outcome = h.send("HEAD", "/letters", headers=[("Range", "bytes=0-1")])
  inspect(
    "\{outcome.plan.status} \{@debug.to_string(matched_id(outcome))}",
    content="404 None",
  )
}

///|
test "an empty body file gets its empty body with 200 and Accept-Ranges, whatever the range" {
  let h = harness([("any.json", any_method)], body_files=[
    ("letters.txt", b"abcdefghijklmnopqrstuvwxyz"),
    ("empty.txt", b""),
  ])
  let out = []
  for range in ["bytes=0-0", "bytes=0-", "bytes=-1", "bytes=-0", "bytes=5-9"] {
    out.push(
      "\{range}:\n" +
      response(h.send("GET", "/empty", headers=[("Range", range)])),
    )
  }
  inspect(
    out.join("\n"),
    content=(
      #|bytes=0-0:
      #|200
      #|Accept-Ranges: bytes
      #|Smock-Mock: media; via=default
      #|
      #|bytes=0-:
      #|200
      #|Accept-Ranges: bytes
      #|Smock-Mock: media; via=default
      #|
      #|bytes=-1:
      #|200
      #|Accept-Ranges: bytes
      #|Smock-Mock: media; via=default
      #|
      #|bytes=-0:
      #|200
      #|Accept-Ranges: bytes
      #|Smock-Mock: media; via=default
      #|
      #|bytes=5-9:
      #|200
      #|Accept-Ranges: bytes
      #|Smock-Mock: media; via=default
      #|
    ),
  )
}

///|
test "a Stub with its own 206, Content-Range or Accept-Ranges is left alone, and so is a templated, inline, json or non-200 response" {
  let h = harness(
    [
      (
        "alone.yaml",
        (
          #|mocks: [{ name: media }]
          #|stubs:
          #|  - id: own-206
          #|    mock: media
          #|    request: { path: /own-206 }
          #|    response: { status: 206, headers: { Content-Range: bytes 0-25/100 }, bodyFile: letters.txt }
          #|  - id: own-content-range
          #|    mock: media
          #|    request: { path: /own-content-range }
          #|    response: { status: 200, headers: { content-range: bytes */26 }, bodyFile: letters.txt }
          #|  - id: own-accept-ranges
          #|    mock: media
          #|    request: { path: /own-accept-ranges }
          #|    response: { status: 200, headers: { ACCEPT-RANGES: none }, bodyFile: letters.txt }
          #|  - id: templated
          #|    mock: media
          #|    request: { path: /templated }
          #|    response: { status: 200, template: true, bodyFile: letters.txt }
          #|  - id: inline
          #|    mock: media
          #|    request: { path: /inline }
          #|    response: { status: 200, body: abcdefghijklmnopqrstuvwxyz }
          #|  - id: json
          #|    mock: media
          #|    request: { path: /json }
          #|    response: { status: 200, json: abcdefghijklmnopqrstuvwxyz }
          #|  - id: not-found
          #|    mock: media
          #|    request: { path: /not-found }
          #|    response: { status: 404, bodyFile: letters.txt }
        ),
      ),
    ],
    body_files=media_files,
  )
  let out = []
  for
    path in [
      "/own-206", "/own-content-range", "/own-accept-ranges", "/templated", "/inline",
      "/json", "/not-found",
    ] {
    out.push(
      "\{path}:\n" +
      response(h.send("GET", path, headers=[("Range", "bytes=0-1")])),
    )
  }
  inspect(
    out.join("\n"),
    content=(
      #|/own-206:
      #|206
      #|Content-Range: bytes 0-25/100
      #|Smock-Mock: media; via=default
      #|abcdefghijklmnopqrstuvwxyz
      #|/own-content-range:
      #|200
      #|content-range: bytes */26
      #|Smock-Mock: media; via=default
      #|abcdefghijklmnopqrstuvwxyz
      #|/own-accept-ranges:
      #|200
      #|ACCEPT-RANGES: none
      #|Smock-Mock: media; via=default
      #|abcdefghijklmnopqrstuvwxyz
      #|/templated:
      #|200
      #|Smock-Mock: media; via=default
      #|abcdefghijklmnopqrstuvwxyz
      #|/inline:
      #|200
      #|Smock-Mock: media; via=default
      #|abcdefghijklmnopqrstuvwxyz
      #|/json:
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: media; via=default
      #|"abcdefghijklmnopqrstuvwxyz"
      #|/not-found:
      #|404
      #|Smock-Mock: media; via=default
      #|abcdefghijklmnopqrstuvwxyz
    ),
  )
}

///|
test "a number too large to hold is past the end: unsatisfiable as a first position, the end as a last, the whole body as a suffix" {
  let h = harness([("media.json", media)], body_files=media_files)
  let ranges = [
    "bytes=99999999999999999999999-", "bytes=9223372036854775808-9223372036854775809",
    "bytes=3-99999999999999999999999", "bytes=0-18446744073709551616", "bytes=-99999999999999999999999",
    "bytes=-4294967296",
    // Compared exactly, the last position is below the first.
     "bytes=99999999999999999999999-99999999999999999999998", "bytes=18446744073709551617-18446744073709551616",
    // Leading zeros count for nothing.
     "bytes=000000000000000000000000000003-0000000000000000000000000000004", "bytes=-000000000000000000000000000002",
  ]
  inspect(
    ranges.map(range => letters_with(h, range)).join("\n"),
    content=(
      #|bytes=99999999999999999999999-: 416 bytes */26 
      #|bytes=9223372036854775808-9223372036854775809: 416 bytes */26 
      #|bytes=3-99999999999999999999999: 206 bytes 3-25/26 defghijklmnopqrstuvwxyz
      #|bytes=0-18446744073709551616: 206 bytes 0-25/26 abcdefghijklmnopqrstuvwxyz
      #|bytes=-99999999999999999999999: 206 bytes 0-25/26 abcdefghijklmnopqrstuvwxyz
      #|bytes=-4294967296: 206 bytes 0-25/26 abcdefghijklmnopqrstuvwxyz
      #|bytes=99999999999999999999999-99999999999999999999998: 200 - abcdefghijklmnopqrstuvwxyz
      #|bytes=18446744073709551617-18446744073709551616: 200 - abcdefghijklmnopqrstuvwxyz
      #|bytes=000000000000000000000000000003-0000000000000000000000000000004: 206 bytes 3-4/26 de
      #|bytes=-000000000000000000000000000002: 206 bytes 24-25/26 yz
    ),
  )
}

///|
test "the 206's body is a view of the body file's bytes, not a copy" {
  let letters = b"abcdefghijklmnopqrstuvwxyz"
  let h = harness([("media.json", media)], body_files=[("letters.txt", letters)])
  let plan = h.send("GET", "/letters", headers=[("Range", "bytes=3-5")]).plan
  guard plan.body is Bytes(body) else { fail("not a byte body") }
  assert_true(physical_equal(body.data(), letters))
  inspect("\{body.start_offset()} \{body.length()}", content="3 3")
}

///|
test "a delay and a partial Fault apply to a 206 and a 416 as usual, and the Journal records the status sent" {
  let h = harness(
    [
      (
        "faults.yaml",
        (
          #|mocks: [{ name: media }]
          #|stubs:
          #|  - id: slow-partial
          #|    mock: media
          #|    request: { method: GET, path: /video.mp4 }
          #|    response:
          #|      status: 200
          #|      headers: { Content-Type: video/mp4 }
          #|      bodyFile: letters.txt
          #|    fault: { delay: { fixed: 250 }, connection: { kind: partial } }
        ),
      ),
    ],
    body_files=media_files,
  )
  inspect(
    describe(h.send("GET", "/video.mp4", headers=[("Range", "bytes=10-19")])) +
    "\n---\n" +
    describe(h.send("GET", "/video.mp4", headers=[("Range", "bytes=26-")])),
    content=(
      #|plan:
      #|  status: 206
      #|  header: Content-Type: video/mp4
      #|  header: Content-Range: bytes 10-19/26
      #|  header: Accept-Ranges: bytes
      #|  header: Smock-Mock: media; via=default
      #|  body: "klmnopqrst"
      #|  delay_ms: 250
      #|  fault: Some(Partial)
      #|journal:
      #|  session: None
      #|  host: None
      #|  mock: Some("media")
      #|  via_default: true
      #|  request: GET /video.mp4 HTTP/1.1
      #|  header: Range: bytes=10-19
      #|  body: ""
      #|  stub: Some("slow-partial")
      #|  status: Some(206)
      #|  fault: Some(Partial)
      #|  received_at: 1791815405123
      #|near_miss: None
      #|---
      #|plan:
      #|  status: 416
      #|  header: Content-Type: video/mp4
      #|  header: Content-Range: bytes */26
      #|  header: Smock-Mock: media; via=default
      #|  body: ""
      #|  delay_ms: 250
      #|  fault: Some(Partial)
      #|journal:
      #|  session: None
      #|  host: None
      #|  mock: Some("media")
      #|  via_default: true
      #|  request: GET /video.mp4 HTTP/1.1
      #|  header: Range: bytes=26-
      #|  body: ""
      #|  stub: Some("slow-partial")
      #|  status: Some(416)
      #|  fault: Some(Partial)
      #|  received_at: 1791815405123
      #|near_miss: None
    ),
  )
}

///|
test "with responses, the response picked decides whether a request is served a range" {
  let h = harness(
    [
      (
        "picked.yaml",
        (
          #|mocks: [{ name: media }]
          #|stubs:
          #|  - id: picked
          #|    mock: media
          #|    request: { method: GET, path: /letters }
          #|    responses:
          #|      - { status: 200, bodyFile: letters.txt }
          #|      - { status: 200, body: abcdefghijklmnopqrstuvwxyz }
          #|    fault: { seed: 7 }
        ),
      ),
    ],
    body_files=media_files,
  )
  let seen = Map([])
  for _ in 0..<50 {
    let outcome = h.send("GET", "/letters", headers=[("Range", "bytes=0-1")])
    guard outcome.journal is Some(entry) else { fail("no Journal entry") }
    seen[@debug.to_string(entry.response_index)] = response(outcome)
  }
  inspect(
    seen.get("Some(0)").unwrap_or("none") +
    "\n---\n" +
    seen.get("Some(1)").unwrap_or("none"),
    content=(
      #|206
      #|Content-Range: bytes 0-1/26
      #|Accept-Ranges: bytes
      #|Smock-Mock: media; via=default
      #|ab
      #|---
      #|200
      #|Smock-Mock: media; via=default
      #|abcdefghijklmnopqrstuvwxyz
    ),
  )
}

///|
test "rendering applies the rule to the sample's Range field, so it shows the 206 or the 416 a request would get" {
  let h = harness([("media.json", media)], body_files=media_files)
  let shown = (sample : Json) => {
    let rendering : @engine.Rendering = h.engine.render(
      "letters",
      @engine.SampleRequest::from_json(sample),
      now=h.now,
      fresh_seed=() => 7,
    )
    guard rendering.to_json() is Object({ "response": response, .. }) else {
      abort("no response")
    }
    response.stringify()
  }
  inspect(
    [
      shown({ "path": "/letters", "headers": { "Range": "bytes=-5" } }),
      shown({ "path": "/letters", "headers": { "Range": "bytes=99-" } }),
      shown({ "path": "/letters" }),
      shown({
        "method": "HEAD",
        "path": "/letters",
        "headers": { "Range": "bytes=0-1" },
      }),
    ].join("\n"),
    content=(
      #|{"status":206,"headers":[{"name":"Content-Type","value":"text/plain"},{"name":"Content-Range","value":"bytes 21-25/26"},{"name":"Accept-Ranges","value":"bytes"}],"body":{"encoding":"utf-8","data":"vwxyz","size":5,"truncated":false},"events":null}
      #|{"status":416,"headers":[{"name":"Content-Type","value":"text/plain"},{"name":"Content-Range","value":"bytes */26"}],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false},"events":null}
      #|{"status":200,"headers":[{"name":"Content-Type","value":"text/plain"},{"name":"Accept-Ranges","value":"bytes"}],"body":{"encoding":"utf-8","data":"abcdefghijklmnopqrstuvwxyz","size":26,"truncated":false},"events":null}
      #|{"status":200,"headers":[{"name":"Content-Type","value":"text/plain"},{"name":"Accept-Ranges","value":"bytes"}],"body":{"encoding":"utf-8","data":"abcdefghijklmnopqrstuvwxyz","size":26,"truncated":false},"events":null}
    ),
  )
}
