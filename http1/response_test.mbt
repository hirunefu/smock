///|
fn encoded(
  status : Int,
  headers : Array[(String, String)],
  body : String,
) -> String {
  @utf8.decode_lossy(
    @http1.encode_response(status, headers, @utf8.encode(body)),
  )
}

///|
test "a response carries its status line, its headers in order, Content-Length and the body" {
  inspect(
    encoded(
      200,
      [("Content-Type", "application/json"), ("X-Trace", "a b")],
      "{\"id\":1}",
    ),
    content=(
      #|HTTP/1.1 200 OK
      #|Content-Type: application/json
      #|X-Trace: a b
      #|Content-Length: 8
      #|
      #|{"id":1}
    ).replace_all(old="\n", new="\r\n"),
  )
}

///|
test "an empty body has Content-Length 0" {
  inspect(
    encoded(404, [], ""),
    content="HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n",
  )
}

///|
test "a status without a known reason phrase gets an empty one" {
  inspect(
    encoded(299, [], ""),
    content="HTTP/1.1 299 \r\nContent-Length: 0\r\n\r\n",
  )
}

///|
test "204 and 304 responses have neither Content-Length nor a body" {
  inspect(
    encoded(204, [("X-A", "1")], "ignored") + encoded(304, [], "ignored"),
    content="HTTP/1.1 204 No Content\r\nX-A: 1\r\n\r\nHTTP/1.1 304 Not Modified\r\n\r\n",
  )
}

///|
test "header values are written as UTF-8" {
  inspect(
    encoded(200, [("X-Name", "café")], ""),
    content="HTTP/1.1 200 OK\r\nX-Name: café\r\nContent-Length: 0\r\n\r\n",
  )
}

///|
test "a response given a Date value carries it after its headers, before the fields that frame it" {
  let request = request_of(
    "GET / HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n",
  )
  inspect(
    one_line(
      @http1.encode_response(
        200,
        [("Content-Type", "text/plain")],
        b"hi",
        request~,
        date="Thu, 22 Oct 2026 14:37:10 GMT",
      ),
    ),
    content="HTTP/1.1 200 OK|Content-Type: text/plain|Date: Thu, 22 Oct 2026 14:37:10 GMT|Connection: close|Content-Length: 2||hi",
  )
}

///|
test "a response whose headers give a Date field, in any case, carries that one alone" {
  let given = ["Date", "date", "DATE", "dAtE"].map(name => {
    one_line(
      @http1.encode_response(
        200,
        [(name, "Mon, 01 Jan 2001 00:00:00 GMT"), ("X-A", "1")],
        b"",
        date="Thu, 22 Oct 2026 14:37:10 GMT",
      ),
    )
  })
  inspect(
    given.join("\n"),
    content=(
      #|HTTP/1.1 200 OK|Date: Mon, 01 Jan 2001 00:00:00 GMT|X-A: 1|Content-Length: 0||
      #|HTTP/1.1 200 OK|date: Mon, 01 Jan 2001 00:00:00 GMT|X-A: 1|Content-Length: 0||
      #|HTTP/1.1 200 OK|DATE: Mon, 01 Jan 2001 00:00:00 GMT|X-A: 1|Content-Length: 0||
      #|HTTP/1.1 200 OK|dAtE: Mon, 01 Jan 2001 00:00:00 GMT|X-A: 1|Content-Length: 0||
    ),
  )
  // Names that only start or end like it are other fields.
  inspect(
    one_line(
      @http1.encode_response(
        204,
        [("Dates", "a"), ("X-Date", "b")],
        b"",
        date="Thu, 22 Oct 2026 14:37:10 GMT",
      ),
    ),
    content="HTTP/1.1 204 No Content|Dates: a|X-Date: b|Date: Thu, 22 Oct 2026 14:37:10 GMT||",
  )
}
