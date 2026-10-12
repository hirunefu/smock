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
