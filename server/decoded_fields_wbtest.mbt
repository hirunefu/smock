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
  // fields; two cookie fields, joined; and values that are not UTF-8.
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
    ),
  )
}
