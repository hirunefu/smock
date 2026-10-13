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
