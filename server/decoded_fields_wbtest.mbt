///|
/// A field of `name` and `value`, its octets new, as moonhttp gives a field
/// that came as a literal.
fn literal(name : String, value : Bytes) -> @header.Header {
  { name: @utf8.encode(name), value: value.to_array() |> Bytes::from_array, }
}

///|
/// What `request` gives the engine, as text.
fn request_text(request : H2Request) -> String {
  let authority = match request.authority {
    Some(authority) => authority
    None => "-"
  }
  let parts = [request.meth, request.target, authority]
  for field in request.headers {
    parts.push(field.0 + "=" + field.1)
  }
  parts.join(" ")
}

///|
test "an HTTP/2 connection's fields decode as each request's would alone, fields sent again included" {
  // Field sections on one connection, as moonhttp gives them: a field sent
  // again from its HPACK table has the very octets of the time before, and
  // one sent again as a literal new octets. The same fields again, both
  // ways; one value changed; a field added; fields in another order; fewer
  // fields; two cookie fields, joined; values that are not UTF-8; and a
  // field's name changed, its value not.
  let meth = literal(":method", b"GET")
  let scheme = literal(":scheme", b"http")
  let path = literal(":path", b"/a")
  let authority = literal(":authority", b"a.example")
  let accept = literal("accept", b"*/*")
  let id = literal("x-id", b"1")
  let pseudo = [meth, scheme, path, authority]
  let sections = [
    [..pseudo, accept, id],
    [..pseudo, accept, id],
    [
      literal(":method", b"GET"),
      literal(":scheme", b"http"),
      literal(":path", b"/a"),
      literal(":authority", b"a.example"),
      literal("accept", b"*/*"),
      literal("x-id", b"1"),
    ],
    [..pseudo, accept, literal("x-id", b"2")],
    [..pseudo, accept, literal("x-id", b"2"), literal("x-new", b"caf\xc3\xa9")],
    [..pseudo, literal("x-id", b"2"), accept, literal("x-new", b"caf\xc3\xa9")],
    [meth, scheme, literal(":path", b"/b")],
    [..pseudo, literal("cookie", b"a=1"), accept, literal("cookie", b"b=2")],
    [..pseudo, literal("cookie", b"a=1"), accept, literal("cookie", b"b=2")],
    [..pseudo, literal("x-raw", b"\xff\xfe")],
    [..pseudo, literal("x-raw", b"\xff\xfe")],
    [..pseudo, literal("x-other", b"\xff\xfe")],
  ]
  let decoded = DecodedFields::new()
  let out = []
  let mut before : Array[(String, String)] = []
  for section in sections {
    let alone = H2Request::new(section, DecodedFields::new(), deadline=0)
    let request = H2Request::new(section, decoded, deadline=0)
    // How many fields are the very ones of the request before.
    let mut shared = 0
    for i, field in request.headers {
      if i < before.length() && physical_equal(field, before[i]) {
        shared += 1
      }
    }
    let same = request.meth == alone.meth &&
      request.target == alone.target &&
      request.authority == alone.authority &&
      request.headers == alone.headers
    out.push(
      if same {
        "same as alone, \{shared} shared: \{request_text(request)}"
      } else {
        "differs from \{request_text(alone)}: \{request_text(request)}"
      },
    )
    before = request.headers
  }
  inspect(
    out.join("\n"),
    content=(
      #|same as alone, 0 shared: GET /a a.example accept=*/* x-id=1
      #|same as alone, 2 shared: GET /a a.example accept=*/* x-id=1
      #|same as alone, 2 shared: GET /a a.example accept=*/* x-id=1
      #|same as alone, 1 shared: GET /a a.example accept=*/* x-id=2
      #|same as alone, 2 shared: GET /a a.example accept=*/* x-id=2 x-new=café
      #|same as alone, 1 shared: GET /a a.example x-id=2 accept=*/* x-new=café
      #|same as alone, 0 shared: GET /b -
      #|same as alone, 0 shared: GET /a a.example cookie=a=1; b=2 accept=*/*
      #|same as alone, 1 shared: GET /a a.example cookie=a=1; b=2 accept=*/*
      #|same as alone, 0 shared: GET /a a.example x-raw=��
      #|same as alone, 1 shared: GET /a a.example x-raw=��
      #|same as alone, 0 shared: GET /a a.example x-other=��
    ),
  )
}

///|
/// How many of the slots of `fields` and `decoded` from `start` on still
/// hold a field or its text.
fn held_past(
  fields : ArrayView[@header.Header],
  decoded : ArrayView[(String, String)],
  start : Int32,
) -> Int32 {
  let mut held = 0
  for i in start..<fields.length() {
    if fields[i].name.length() > 0 || decoded[i].0 != "" {
      held += 1
    }
  }
  held
}

///|
test "an HTTP/2 connection keeps the fields of its last section alone, not those past it of a longer section before" {
  // A section, a shorter one, and the first again. Views taken after the
  // first see every slot of the arrays, past their length too, where
  // truncated arrays would still hold the fields they dropped.
  let long = [
    literal(":method", b"GET"),
    literal(":scheme", b"http"),
    literal(":path", b"/a"),
    literal(":authority", b"a.example"),
    literal("accept", b"*/*"),
    literal("x-id", b"1"),
  ]
  let short = [long[0], long[1], literal(":path", b"/b")]
  let decoded = DecodedFields::new()
  let mut fields = decoded.fields[:]
  let mut texts = decoded.decoded[:]
  let out = []
  for i, section in [long, short, long] {
    let alone = H2Request::new(section, DecodedFields::new(), deadline=0)
    let request = H2Request::new(section, decoded, deadline=0)
    if i == 0 {
      fields = decoded.fields[:]
      texts = decoded.decoded[:]
    }
    let same = request.meth == alone.meth &&
      request.target == alone.target &&
      request.authority == alone.authority &&
      request.headers == alone.headers
    let kept = decoded.fields.length()
    out.push(
      "\{kept} kept, \{decoded.decoded.length()} decoded, " +
      "\{held_past(fields, texts, kept)} held past them, " +
      "same as alone: \{same}",
    )
  }
  inspect(
    out.join("\n"),
    content=(
      #|6 kept, 6 decoded, 0 held past them, same as alone: true
      #|3 kept, 3 decoded, 0 held past them, same as alone: true
      #|6 kept, 6 decoded, 0 held past them, same as alone: true
    ),
  )
}

///|
test "an HTTP/2 connection holds at most one field section's worth of fields, however its sections shrink" {
  // Sections that each cost exactly the default --header-size-limit, so
  // that each passes it: from 492 fields after the pseudo-header fields,
  // the most that fit, down to 1, as (m - 1) empty `a` fields and a `b`
  // field whose value takes the rest. Sections of more than
  // --header-count-limit fields are decoded before they are refused, and a
  // refusal leaves the connection open. Were the slots past each section
  // kept, they would hold the `b` of every longer section before: about
  // 4 MB, and their text. Views taken after the first section see every
  // slot of the arrays, past their length too.
  let limit = 16 * 1024
  let a = literal("a", b"")
  let decoded = DecodedFields::new()
  let mut fields = decoded.fields[:]
  let mut texts = decoded.decoded[:]
  let mut over = 0
  let mut most = 0
  for m = 492; m >= 1; m = m - 1 {
    let section = [
      literal(":method", b"GET"),
      literal(":scheme", b"http"),
      literal(":path", b"/"),
    ]
    for _ in 1..<m {
      section.push(a)
    }
    section.push(literal("b", Bytes::make(16261 - 33 * m, b'x')))
    if is_list_over(section, limit) {
      over += 1
    }
    let _ = H2Request::new(section, decoded, deadline=0)
    if m == 492 {
      fields = decoded.fields[:]
      texts = decoded.decoded[:]
    }
    let cost = decoded.fields.fold(init=0, (sum, field) => sum + field.cost())
    if cost > most {
      most = cost
    }
  }
  let mut octets = 0
  let mut characters = 0
  for i in 0..<fields.length() {
    octets += fields[i].name.length() + fields[i].value.length()
    characters += texts[i].0.length() + texts[i].1.length()
  }
  inspect(
    (
      $|sections over the limit: \{over}
      $|fields kept: \{decoded.fields.length()}
      $|most cost kept after a section: \{most}
      $|octets in every slot: \{octets}
      $|characters in every slot: \{characters}
    ),
    content=(
      #|sections over the limit: 0
      #|fields kept: 4
      #|most cost kept after a section: 16384
      #|octets in every slot: 16256
      #|characters in every slot: 16256
    ),
  )
}
