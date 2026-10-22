// The Server-Sent Event encoder and streamed responses, through the
// module's public interface.

///|
fn sse(data : String, event? : String, id? : String) -> String {
  @utf8.decode_lossy(@http1.encode_sse_event(data, event?, id?))
}

///|
/// Everything a streamed response to `request` writes when its body is
/// `parts`: the head, each part as framed, and the end of the body, with
/// each CRLF shown as `\r\n` at the end of a line. Then whether the
/// connection stays open after it.
fn streamed(
  status : Int,
  headers : Array[(String, String)],
  parts : Array[String],
  request? : @http1.Request,
  close? : Bool = false,
  date? : String,
) -> String {
  let stream = @http1.ResponseStream(status, headers, request?, close~, date?)
  let out = @buffer.Buffer()
  out.write_bytes(stream.head())
  for part in parts {
    out.write_bytes(stream.part(@utf8.encode(part)))
  }
  out.write_bytes(stream.end())
  let after = if stream.keeps_open() { "open" } else { "closed" }
  @utf8.decode_lossy(out.to_bytes()).replace_all(old="\r\n", new="\\r\\n\n") +
  "[\{after}]"
}

///|
test "a streamed response to HTTP/1.1 is chunked: one chunk per part, then the last chunk, and the connection stays open" {
  inspect(
    streamed(
      200,
      [("Content-Type", "text/event-stream")],
      ["data: a\n\n", "data: 0123456789abcdef\n\n"],
      request=request_of("GET /events HTTP/1.1\r\nHost: a\r\n\r\n"),
    ),
    content=(
      #|HTTP/1.1 200 OK\r\n
      #|Content-Type: text/event-stream\r\n
      #|Transfer-Encoding: chunked\r\n
      #|\r\n
      #|9\r\n
      #|data: a
      #|
      #|\r\n
      #|18\r\n
      #|data: 0123456789abcdef
      #|
      #|\r\n
      #|0\r\n
      #|\r\n
      #|[open]
    ),
  )
}

///|
test "a streamed response to HTTP/1.0 is never chunked: the parts as they are, and the connection closes to end it, even when the request asks to keep it open" {
  inspect(
    streamed(
      200,
      [("Content-Type", "text/event-stream")],
      ["data: a\n\n", "data: b\n\n"],
      request=request_of(
        "GET /events HTTP/1.0\r\nConnection: keep-alive\r\n\r\n",
      ),
    ),
    content=(
      #|HTTP/1.1 200 OK\r\n
      #|Content-Type: text/event-stream\r\n
      #|Connection: close\r\n
      #|\r\n
      #|data: a
      #|
      #|data: b
      #|
      #|[closed]
    ),
  )
}

///|
test "a streamed response to HTTP/1.1 that closes the connection after it is still chunked, and says Connection: close" {
  let asks_to_close = request_of(
    "GET /events HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n",
  )
  let keep_alive = request_of("GET /events HTTP/1.1\r\nHost: a\r\n\r\n")
  inspect(
    streamed(200, [], ["x"], request=asks_to_close) +
    "\n---\n" +
    streamed(200, [], ["x"], request=keep_alive, close=true),
    content=(
      #|HTTP/1.1 200 OK\r\n
      #|Connection: close\r\n
      #|Transfer-Encoding: chunked\r\n
      #|\r\n
      #|1\r\n
      #|x\r\n
      #|0\r\n
      #|\r\n
      #|[closed]
      #|---
      #|HTTP/1.1 200 OK\r\n
      #|Connection: close\r\n
      #|Transfer-Encoding: chunked\r\n
      #|\r\n
      #|1\r\n
      #|x\r\n
      #|0\r\n
      #|\r\n
      #|[closed]
    ),
  )
}

///|
test "a streamed response given a Date value carries it in its head, after its headers and before the fields that frame it, unless its headers give one in any case" {
  let request = request_of(
    "GET /events HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n",
  )
  let date = "Thu, 22 Oct 2026 14:37:10 GMT"
  inspect(
    streamed(
      200,
      [("Content-Type", "text/event-stream")],
      ["x"],
      request~,
      date~,
    ) +
    "\n---\n" +
    streamed(
      200,
      [("DATE", "Mon, 01 Jan 2001 00:00:00 GMT")],
      [],
      request~,
      date~,
    ),
    content=(
      #|HTTP/1.1 200 OK\r\n
      #|Content-Type: text/event-stream\r\n
      #|Date: Thu, 22 Oct 2026 14:37:10 GMT\r\n
      #|Connection: close\r\n
      #|Transfer-Encoding: chunked\r\n
      #|\r\n
      #|1\r\n
      #|x\r\n
      #|0\r\n
      #|\r\n
      #|[closed]
      #|---
      #|HTTP/1.1 200 OK\r\n
      #|DATE: Mon, 01 Jan 2001 00:00:00 GMT\r\n
      #|Connection: close\r\n
      #|Transfer-Encoding: chunked\r\n
      #|\r\n
      #|0\r\n
      #|\r\n
      #|[closed]
    ),
  )
}

///|
test "an empty part writes nothing, so it cannot end a chunked body early" {
  let request = request_of("GET /events HTTP/1.1\r\nHost: a\r\n\r\n")
  inspect(
    streamed(200, [], ["", "x", ""], request~),
    content=(
      #|HTTP/1.1 200 OK\r\n
      #|Transfer-Encoding: chunked\r\n
      #|\r\n
      #|1\r\n
      #|x\r\n
      #|0\r\n
      #|\r\n
      #|[open]
    ),
  )
}

///|
test "a streamed response to HEAD has the head a GET would get, and no body" {
  inspect(
    streamed(
      200,
      [],
      ["data: a\n\n"],
      request=request_of("HEAD /events HTTP/1.1\r\nHost: a\r\n\r\n"),
    ) +
    "\n---\n" +
    streamed(
      200,
      [],
      ["data: a\n\n"],
      request=request_of("HEAD /events HTTP/1.0\r\n\r\n"),
    ),
    content=(
      #|HTTP/1.1 200 OK\r\n
      #|Transfer-Encoding: chunked\r\n
      #|\r\n
      #|[open]
      #|---
      #|HTTP/1.1 200 OK\r\n
      #|Connection: close\r\n
      #|\r\n
      #|[closed]
    ),
  )
}

///|
test "a streamed response with status 204 or 304 has no body, so neither Transfer-Encoding nor a close ends it" {
  inspect(
    streamed(
      204,
      [("X-A", "1")],
      ["data: a\n\n"],
      request=request_of("GET /events HTTP/1.1\r\nHost: a\r\n\r\n"),
    ) +
    "\n---\n" +
    streamed(
      304,
      [],
      ["data: a\n\n"],
      request=request_of(
        "GET /events HTTP/1.0\r\nConnection: keep-alive\r\n\r\n",
      ),
    ),
    content=(
      #|HTTP/1.1 204 No Content\r\n
      #|X-A: 1\r\n
      #|\r\n
      #|[open]
      #|---
      #|HTTP/1.1 304 Not Modified\r\n
      #|Connection: keep-alive\r\n
      #|\r\n
      #|[open]
    ),
  )
}

///|
test "an event with only data is one data field and the blank line that ends it" {
  inspect(sse("hello"), content="data: hello\n\n")
}

///|
test "data with several lines becomes one data field per line, whatever ends the lines" {
  inspect(
    sse("line 1\nline 2\r\nline 3\rline 4"),
    content=(
      #|data: line 1
      #|data: line 2
      #|data: line 3
      #|data: line 4
      #|
      #|
    ),
  )
}

///|
test "empty lines in data, and a line break at its end, are data fields of their own" {
  inspect(
    [sse(""), sse("a\n\nb"), sse("a\n"), sse("\n")].join("---\n"),
    content=(
      #|data:
      #|
      #|---
      #|data: a
      #|data:
      #|data: b
      #|
      #|---
      #|data: a
      #|data:
      #|
      #|---
      #|data:
      #|data:
      #|
      #|
    ),
  )
}

///|
test "an event's type and ID come before its data, each only when given" {
  inspect(
    [
      sse("x", event="update", id="7"),
      sse("x", event="update"),
      sse("x", id="7"),
      sse("x", event="", id=""),
    ].join("---\n"),
    content=(
      #|event: update
      #|id: 7
      #|data: x
      #|
      #|---
      #|event: update
      #|data: x
      #|
      #|---
      #|id: 7
      #|data: x
      #|
      #|---
      #|event:
      #|id:
      #|data: x
      #|
      #|
    ),
  )
}

///|
test "a value that starts with a space keeps it, and text is written as UTF-8" {
  let bytes = @http1.encode_sse_event(" café", event=" ü", id=" 1")
  inspect(
    @utf8.decode_lossy(bytes),
    content=(
      #|event:  ü
      #|id:  1
      #|data:  café
      #|
      #|
    ),
  )
  // 11 bytes of event, 7 of id, 13 of data and the blank line: ü and é
  // take two bytes each.
  inspect(bytes.length(), content="32")
}
