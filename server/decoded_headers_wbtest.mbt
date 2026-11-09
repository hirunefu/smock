///|
test "a connection's header fields decode as each request's would alone, fields sent again included" {
  // Requests on one connection: the same fields again, one value changed,
  // a field added, fields in another order, fewer fields, a name in
  // another case, and values that are not UTF-8.
  let stream = "GET /a HTTP/1.1\r\nHost: a.example\r\nAccept: */*\r\nX-Id: 1\r\n\r\n" +
    "GET /a HTTP/1.1\r\nHost: a.example\r\nAccept: */*\r\nX-Id: 1\r\n\r\n" +
    "GET /a HTTP/1.1\r\nHost: a.example\r\nAccept: */*\r\nX-Id: 2\r\n\r\n" +
    "GET /b HTTP/1.1\r\nHost: a.example\r\nAccept: */*\r\nX-Id: 2\r\nX-New: caf\u{e9}\r\n\r\n" +
    "GET /b HTTP/1.1\r\nAccept: */*\r\nHost: a.example\r\nX-Id: 2\r\nX-New: caf\u{e9}\r\n\r\n" +
    "GET /b HTTP/1.1\r\nHost: a.example\r\n\r\n" +
    "GET /b HTTP/1.1\r\nhost: a.example\r\nAccept: */*\r\n\r\n"
  let bytes = @buffer.Buffer()
  bytes.write_string_utf8(stream)
  bytes.write_bytes(
    b"GET /c HTTP/1.1\r\nHost: a.example\r\nX-Raw: \xff\xfe\r\n\r\n",
  )
  bytes.write_bytes(
    b"GET /c HTTP/1.1\r\nHost: a.example\r\nX-Raw: \xff\xfe\r\n\r\n",
  )
  let parser = @http1.Parser()
  parser.feed(bytes.to_bytes()[:])
  let headers = DecodedHeaders::new()
  let out = []
  let mut before : Array[(String, String)] = []
  while parser.next() is Complete(request) {
    let expected = decoded_headers(request)
    let actual = headers.of(request)
    let text = actual.map(field => field.0 + "=" + field.1).join(" ")
    // How many fields are the very ones of the request before.
    let mut shared = 0
    for i, field in actual {
      if i < before.length() && physical_equal(field, before[i]) {
        shared += 1
      }
    }
    out.push(
      if actual == expected {
        "same as alone, \{shared} shared: \{text}"
      } else {
        "differs from \{expected.map(field => field.0 + "=" + field.1).join(" ")}: \{text}"
      },
    )
    before = actual
  }
  inspect(
    out.join("\n"),
    content=(
      #|same as alone, 0 shared: Host=a.example Accept=*/* X-Id=1
      #|same as alone, 3 shared: Host=a.example Accept=*/* X-Id=1
      #|same as alone, 2 shared: Host=a.example Accept=*/* X-Id=2
      #|same as alone, 3 shared: Host=a.example Accept=*/* X-Id=2 X-New=café
      #|same as alone, 2 shared: Accept=*/* Host=a.example X-Id=2 X-New=café
      #|same as alone, 0 shared: Host=a.example
      #|same as alone, 0 shared: host=a.example Accept=*/*
      #|same as alone, 0 shared: Host=a.example X-Raw=��
      #|same as alone, 2 shared: Host=a.example X-Raw=��
    ),
  )
}

///|
/// How many of the slots of `fields` and `decoded` from `start` on still
/// hold a header field or its text.
fn headers_held_past(
  fields : ArrayView[@http1.Header],
  decoded : ArrayView[(String, String)],
  start : Int32,
) -> Int32 {
  let mut held = 0
  for i in start..<fields.length() {
    if fields[i].name != "" || decoded[i].0 != "" {
      held += 1
    }
  }
  held
}

///|
/// The request `head` makes, parsed alone.
fn parsed(head : Bytes) -> @http1.Request {
  let parser = @http1.Parser()
  parser.feed(head[:])
  guard parser.next() is Complete(request) else { abort("not a request") }
  request
}

///|
test "a connection keeps the header fields of its last request alone, not those past them of a longer request before" {
  // A request, a shorter one, and the first again. Views taken after the
  // first see every slot of the arrays, past their length too, where
  // truncated arrays would still hold the fields they dropped.
  let long = b"GET /a HTTP/1.1\r\nHost: a.example\r\nAccept: */*\r\nX-Id: 1\r\n\r\n"
  let short = b"GET /b HTTP/1.1\r\nHost: a.example\r\n\r\n"
  let headers = DecodedHeaders::new()
  let mut fields = headers.fields[:]
  let mut texts = headers.decoded[:]
  let out = []
  for i, head in [long, short, long] {
    let request = parsed(head)
    let actual = headers.of(request)
    if i == 0 {
      fields = headers.fields[:]
      texts = headers.decoded[:]
    }
    let kept = headers.fields.length()
    out.push(
      "\{kept} kept, \{headers.decoded.length()} decoded, " +
      "\{headers_held_past(fields, texts, kept)} held past them, " +
      "same as alone: \{actual == decoded_headers(request)}",
    )
  }
  inspect(
    out.join("\n"),
    content=(
      #|3 kept, 3 decoded, 0 held past them, same as alone: true
      #|1 kept, 1 decoded, 0 held past them, same as alone: true
      #|3 kept, 3 decoded, 0 held past them, same as alone: true
    ),
  )
}

///|
test "a connection holds at most one request's worth of header fields, however its requests shrink" {
  // Request heads that each take exactly the default
  // --header-size-limit, so that each passes it: from 100 fields, the
  // default --header-count-limit, down to 2, as a Host field, (k) empty `A`
  // fields and a `B` field whose value takes the rest. Were the slots past
  // each request kept, they would hold the `B` of every longer request
  // before: about 1.6 MB, and their text. Views taken after the first
  // request see every slot of the arrays, past their length too.
  let headers = DecodedHeaders::new()
  let mut fields = headers.fields[:]
  let mut texts = headers.decoded[:]
  let mut most = 0
  for k = 98; k >= 0; k = k - 1 {
    let head = @buffer.Buffer()
    head.write_bytes(b"GET / HTTP/1.1\r\nHost: a\r\n")
    for _ in 0..<k {
      head.write_bytes(b"A:\r\n")
    }
    head.write_bytes(b"B:")
    head.write_bytes(Bytes::make(16353 - 4 * k, b'x'))
    head.write_bytes(b"\r\n\r\n")
    let _ = headers.of(parsed(head.to_bytes()))
    if k == 98 {
      fields = headers.fields[:]
      texts = headers.decoded[:]
    }
    let mut octets = 0
    for field in headers.fields {
      octets += field.name.length() + field.value.length()
    }
    if octets > most {
      most = octets
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
      $|fields kept: \{headers.fields.length()}
      $|most octets kept after a request: \{most}
      $|octets in every slot: \{octets}
      $|characters in every slot: \{characters}
    ),
    content=(
      #|fields kept: 2
      #|most octets kept after a request: 16359
      #|octets in every slot: 16359
      #|characters in every slot: 16359
    ),
  )
}
