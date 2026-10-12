///|
/// Feeds `chunks` to a new parser one after another and renders what `next`
/// returns after each one, until it needs more bytes.
fn parse_all(chunks : Array[String]) -> String {
  let parser = @http1.Parser()
  let out = StringBuilder()
  for chunk in chunks {
    parser.feed(@utf8.encode(chunk))
    for ;; {
      let parsed = parser.next()
      out.write_string(render(parsed))
      out.write_char('\n')
      if !(parsed is Complete(_)) {
        break
      }
    }
  }
  out.to_string()
}

///|
fn render(parsed : @http1.Parsed) -> String {
  match parsed {
    NeedMore => "need more"
    Invalid(status~) => "invalid \{status}"
    Complete(req) => {
      let out = StringBuilder()
      let version = match req.version {
        Http10 => "HTTP/1.0"
        Http11 => "HTTP/1.1"
      }
      out.write_string("\{req.meth} \{req.target} \{version}")
      for header in req.headers {
        out.write_string(
          " | \{header.name}: \{@utf8.decode_lossy(header.value)}",
        )
      }
      out.write_string(" | body=\{@utf8.decode_lossy(req.body).escape()}")
      out.write_string(
        if req.keep_alive {
          " | keep-alive"
        } else {
          " | close"
        },
      )
      out.to_string()
    }
  }
}

///|
test "a GET request with headers is complete once its head has arrived" {
  inspect(
    parse_all([
      "GET /users/1?x=y HTTP/1.1\r\nHost: a.example\r\nAccept: */*\r\n\r\n",
    ]),
    content=(
      #|GET /users/1?x=y HTTP/1.1 | Host: a.example | Accept: */* | body="" | keep-alive
      #|need more
      #|
    ),
  )
}

///|
test "a body framed by Content-Length is complete once all of it has arrived" {
  inspect(
    parse_all([
      "POST /orders HTTP/1.1\r\nHost: a.example\r\nContent-Length: 12\r\n\r\n{\"id\":",
      "1}\r\n", "\r\n",
    ]),
    content=(
      #|need more
      #|need more
      #|POST /orders HTTP/1.1 | Host: a.example | Content-Length: 12 | body="{\"id\":1}\r\n\r\n" | keep-alive
      #|need more
      #|
    ),
  )
}

///|
test "requests that follow each other on one connection come out in turn, each saying whether the connection stays open" {
  inspect(
    parse_all([
      "GET /a HTTP/1.1\r\nHost: a.example\r\n\r\n", "GET /b HTTP/1.1\r\nHost: a.example\r\nConnection: Keep-Alive, Close\r\n\r\n",
      "GET /c HTTP/1.0\r\n\r\n", "GET /d HTTP/1.0\r\nConnection: keep-alive\r\n\r\n",
    ]),
    content=(
      #|GET /a HTTP/1.1 | Host: a.example | body="" | keep-alive
      #|need more
      #|GET /b HTTP/1.1 | Host: a.example | Connection: Keep-Alive, Close | body="" | close
      #|need more
      #|GET /c HTTP/1.0 | body="" | close
      #|need more
      #|GET /d HTTP/1.0 | Connection: keep-alive | body="" | keep-alive
      #|need more
      #|
    ),
  )
}

///|
test "a request that cannot be parsed gets 400" {
  let cases = [
    "GET\r\n\r\n", "GET /a\r\n\r\n", "GET /a HTTP/1.1 extra\r\nHost: a\r\n\r\n",
    "GET /a FTP/1.1\r\nHost: a\r\n\r\n", "G(T /a HTTP/1.1\r\nHost: a\r\n\r\n", "GET /a HTTP/1.1\r\nHost a\r\n\r\n",
    "GET /a HTTP/1.1\r\nHost : a\r\n\r\n", "GET /a HTTP/1.1\r\n: a\r\nHost: a\r\n\r\n",
    "GET /a HTTP/1.1\r\nHost: a\r\nX: \u{01}\r\n\r\n", "GET /a HTTP/1.1\r\nHost: a\r\n folded\r\n\r\n",
    "GET /a HTTP/1.1\r\n\r\n", "GET /a HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n", "POST /a HTTP/1.1\r\nHost: a\r\nContent-Length: 1x\r\n\r\n",
    "POST /a HTTP/1.1\r\nHost: a\r\nContent-Length: \r\n\r\n", "POST /a HTTP/1.1\r\nHost: a\r\nContent-Length: -1\r\n\r\n",
    "POST /a HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
  ]
  inspect(
    cases.map(case => parse_all([case]).trim_end(char_set="\n")).join("\n"),
    content=(
      #|invalid 400
      #|invalid 400
      #|invalid 400
      #|invalid 400
      #|invalid 400
      #|invalid 400
      #|invalid 400
      #|invalid 400
      #|invalid 400
      #|invalid 400
      #|invalid 400
      #|invalid 400
      #|invalid 400
      #|invalid 400
      #|invalid 400
      #|invalid 400
    ),
  )
}

///|
test "a body framed by Transfer-Encoding is not supported yet" {
  inspect(
    parse_all([
      "POST /a HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nx\r\n0\r\n\r\n",
    ]),
    content=(
      #|invalid 501
      #|
    ),
  )
}

///|
test "after an invalid request the parser stays invalid" {
  let parser = @http1.Parser()
  parser.feed(b"BAD\r\n\r\n")
  inspect(parser.next() is Invalid(status=400), content="true")
  parser.feed(b"GET / HTTP/1.1\r\nHost: a\r\n\r\n")
  inspect(parser.next() is Invalid(status=400), content="true")
}

///|
test "a large body arriving in many pieces, between other requests, is kept whole" {
  let body = "0123456789".repeat(3000)
  let stream = "GET /first HTTP/1.1\r\nHost: a.example\r\n\r\nPUT /blob HTTP/1.1\r\nHost: a.example\r\nContent-Length: 30000\r\n\r\n\{body}GET /next HTTP/1.1\r\nHost: a.example\r\n\r\n"
  let parser = @http1.Parser()
  let bytes = @utf8.encode(stream)
  let requests = []
  for offset = 0; offset < bytes.length(); offset = offset + 1000 {
    let end = if offset + 1000 < bytes.length() {
      offset + 1000
    } else {
      bytes.length()
    }
    parser.feed(bytes[offset:end])
    while parser.next() is Complete(req) {
      requests.push(req)
    }
  }
  inspect(
    requests
    .map(req => "\{req.meth} \{req.target} \{req.body.length()}")
    .join(", "),
    content="GET /first 0, PUT /blob 30000, GET /next 0",
  )
  inspect(requests[1].body == @utf8.encode(body), content="true")
}
