// The connection policy: whether a connection stays open after a response,
// what the response says about it, HEAD responses, HTTP/1.0 clients and
// `Expect: 100-continue`.

///|
/// The request that `head`, a request without a body, parses to.
fn request_of(head : String) -> @http1.Request {
  let parser = @http1.Parser()
  parser.feed(@utf8.encode(head))
  guard parser.next() is Complete(request) else {
    abort("not a complete request: \{head}")
  }
  request
}

///|
/// `bytes` with each CRLF shown as `|`.
fn one_line(bytes : Bytes) -> String {
  @utf8.decode_lossy(bytes).replace_all(old="\r\n", new="|")
}

///|
test "HTTP/1.1 keeps the connection open unless the request says Connection: close; HTTP/1.0 closes it unless the request says Connection: keep-alive; tokens are compared case-insensitively" {
  let cases = [
    ("HTTP/1.1", ""),
    ("HTTP/1.1", "Connection: close\r\n"),
    ("HTTP/1.1", "Connection: CLOSE\r\n"),
    ("HTTP/1.1", "Connection: Upgrade, Close\r\n"),
    ("HTTP/1.1", "Connection: keep-alive\r\nConnection: close\r\n"),
    ("HTTP/1.1", "Connection: keep-alive\r\n"),
    ("HTTP/1.1", "Connection: closed\r\n"),
    ("HTTP/1.1", "X-Connection: close\r\n"),
    ("HTTP/1.0", ""),
    ("HTTP/1.0", "Connection: keep-alive\r\n"),
    ("HTTP/1.0", "Connection: KEEP-ALIVE\r\n"),
    ("HTTP/1.0", "Connection: Upgrade,\tKeep-Alive \r\n"),
    ("HTTP/1.0", "Connection: keep-alive, close\r\n"),
    ("HTTP/1.0", "Connection: keep-alived\r\n"),
  ]
  inspect(
    cases
    .map(case => {
      let (version, fields) = case
      let request = request_of("GET / \{version}\r\nHost: a\r\n\{fields}\r\n")
      let decision = if request.keep_alive { "keep-alive" } else { "close" }
      "\{version} \{shown(fields)} -> \{decision}"
    })
    .join("\n"),
    content=(
      #|HTTP/1.1 "" -> keep-alive
      #|HTTP/1.1 "Connection: close\r\n" -> close
      #|HTTP/1.1 "Connection: CLOSE\r\n" -> close
      #|HTTP/1.1 "Connection: Upgrade, Close\r\n" -> close
      #|HTTP/1.1 "Connection: keep-alive\r\nConnection: close\r\n" -> close
      #|HTTP/1.1 "Connection: keep-alive\r\n" -> keep-alive
      #|HTTP/1.1 "Connection: closed\r\n" -> keep-alive
      #|HTTP/1.1 "X-Connection: close\r\n" -> keep-alive
      #|HTTP/1.0 "" -> close
      #|HTTP/1.0 "Connection: keep-alive\r\n" -> keep-alive
      #|HTTP/1.0 "Connection: KEEP-ALIVE\r\n" -> keep-alive
      #|HTTP/1.0 "Connection: Upgrade,\tKeep-Alive \r\n" -> keep-alive
      #|HTTP/1.0 "Connection: keep-alive, close\r\n" -> close
      #|HTTP/1.0 "Connection: keep-alived\r\n" -> close
    ),
  )
}

///|
test "a response after which the connection closes says Connection: close, and keeps_open says so; a response to HTTP/1.0 that keeps it open says Connection: keep-alive" {
  let cases = [
    ("GET / HTTP/1.1\r\nHost: a\r\n\r\n", false),
    ("GET / HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n", false),
    ("GET / HTTP/1.0\r\n\r\n", false),
    ("GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n", false),
    // The server closes the connection anyway, such as when it stops.
    ("GET / HTTP/1.1\r\nHost: a\r\n\r\n", true),
    ("GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n", true),
  ]
  inspect(
    cases
    .map(case => {
      let (head, close) = case
      let request = request_of(head)
      let response = @http1.encode_response(
        200,
        [("X-A", "1")],
        b"hello",
        request~,
        close~,
      )
      let after = if @http1.keeps_open(request~, close~) {
        "open"
      } else {
        "closed"
      }
      "\{shown(head)} close=\{close}\n  -> \{one_line(response)} then \{after}"
    })
    .join("\n"),
    content=(
      #|"GET / HTTP/1.1\r\nHost: a\r\n\r\n" close=false
      #|  -> HTTP/1.1 200 OK|X-A: 1|Content-Length: 5||hello then open
      #|"GET / HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n" close=false
      #|  -> HTTP/1.1 200 OK|X-A: 1|Connection: close|Content-Length: 5||hello then closed
      #|"GET / HTTP/1.0\r\n\r\n" close=false
      #|  -> HTTP/1.1 200 OK|X-A: 1|Connection: close|Content-Length: 5||hello then closed
      #|"GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n" close=false
      #|  -> HTTP/1.1 200 OK|X-A: 1|Connection: keep-alive|Content-Length: 5||hello then open
      #|"GET / HTTP/1.1\r\nHost: a\r\n\r\n" close=true
      #|  -> HTTP/1.1 200 OK|X-A: 1|Connection: close|Content-Length: 5||hello then closed
      #|"GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n" close=true
      #|  -> HTTP/1.1 200 OK|X-A: 1|Connection: close|Content-Length: 5||hello then closed
    ),
  )
}

///|
test "a response that answers no parsed request says Connection: close only when the connection closes" {
  inspect(
    one_line(@http1.encode_response(400, [], b"", close=true)) +
    " \{@http1.keeps_open(close=true)}\n" +
    one_line(@http1.encode_response(404, [], b"")) +
    " \{@http1.keeps_open()}",
    content=(
      #|HTTP/1.1 400 Bad Request|Connection: close|Content-Length: 0|| false
      #|HTTP/1.1 404 Not Found|Content-Length: 0|| true
    ),
  )
}

///|
test "a response to HEAD carries the Content-Length its body would have, but no body; the request after HEAD is parsed as usual" {
  let parser = @http1.Parser()
  parser.feed(
    b"HEAD /a HTTP/1.1\r\nHost: a\r\n\r\nGET /a HTTP/1.1\r\nHost: a\r\n\r\n",
  )
  let responses = []
  while parser.next() is Complete(request) {
    responses.push(
      one_line(
        @http1.encode_response(
          200,
          [("Content-Type", "text/plain")],
          b"hello",
          request~,
        ),
      ),
    )
  }
  inspect(
    responses.join("\n"),
    content=(
      #|HTTP/1.1 200 OK|Content-Type: text/plain|Content-Length: 5||
      #|HTTP/1.1 200 OK|Content-Type: text/plain|Content-Length: 5||hello
    ),
  )
  inspect(
    one_line(
      @http1.encode_response(
        404,
        [],
        b"",
        request=request_of("HEAD /a HTTP/1.0\r\nConnection: keep-alive\r\n\r\n"),
      ),
    ),
    content="HTTP/1.1 404 Not Found|Connection: keep-alive|Content-Length: 0||",
  )
}

///|
test "a response to HTTP/1.0 is framed by Content-Length, never chunked" {
  let body = b"x".repeat(100_000)
  let response = one_line(
    @http1.encode_response(
      200,
      [],
      body,
      request=request_of("GET / HTTP/1.0\r\n\r\n"),
    ),
  )
  let head_end = response.find("||").unwrap_or(0)
  inspect(
    response[:head_end],
    content="HTTP/1.1 200 OK|Connection: close|Content-Length: 100000",
  )
  inspect(response[head_end + 2:] == "x".repeat(100_000), content="true")
}

///|
test "1xx responses carry neither Content-Length nor a body" {
  inspect(
    one_line(@http1.encode_response(100, [], b"")) +
    "\n" +
    one_line(@http1.encode_response(103, [("Link", "</a>")], b"ignored")),
    content=(
      #|HTTP/1.1 100 Continue||
      #|HTTP/1.1 103 |Link: </a>||
    ),
  )
}

///|
test "the parser tells whether part of a request has arrived, so that the server knows which timeout runs" {
  let parser = @http1.Parser()
  let steps = []
  let step = (bytes : String) => {
    parser.feed(@utf8.encode(bytes))
    let taken = []
    for ;; {
      match parser.next() {
        Complete(request) => taken.push(request.target)
        Continue => taken.push("continue")
        NeedMore => break
        Invalid(status~) => break taken.push("invalid \{status}")
      }
    }
    steps.push(
      "\{shown(bytes)} -> \{taken.join(", ")} | in request: \{parser.in_request()}",
    )
  }
  steps.push("nothing fed | in request: \{parser.in_request()}")
  step("G")
  step("ET /a HTTP/1.1\r\nHost: a\r\n\r\n")
  step("\r\n\r\n")
  step("GET /b HTTP/1.1\r\nHost: a\r\n\r\nGET /c HTTP/1.1\r\n")
  step("Host: a\r\n\r\n")
  step("POST /d HTTP/1.1\r\nHost: a\r\nContent-Length: 2\r\n\r\n")
  step("ok")
  step(
    "POST /e HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n",
  )
  step("0\r\n\r\n")
  step(
    "POST /f HTTP/1.1\r\nHost: a\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\n",
  )
  step("ok")
  inspect(
    steps.join("\n"),
    content=(
      #|nothing fed | in request: false
      #|"G" ->  | in request: true
      #|"ET /a HTTP/1.1\r\nHost: a\r\n\r\n" -> /a | in request: false
      #|"\r\n\r\n" ->  | in request: false
      #|"GET /b HTTP/1.1\r\nHost: a\r\n\r\nGET /c HTTP/1.1\r\n" -> /b | in request: true
      #|"Host: a\r\n\r\n" -> /c | in request: false
      #|"POST /d HTTP/1.1\r\nHost: a\r\nContent-Length: 2\r\n\r\n" ->  | in request: true
      #|"ok" -> /d | in request: false
      #|"POST /e HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n" ->  | in request: true
      #|"0\r\n\r\n" -> /e | in request: false
      #|"POST /f HTTP/1.1\r\nHost: a\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\n" -> continue | in request: true
      #|"ok" -> /f | in request: false
    ),
  )
}

///|
test "Expect: 100-continue on an HTTP/1.1 request with a body within the body limit asks for 100 Continue once its head has arrived, before its body" {
  let parser = @http1.Parser(body_limit=16)
  let steps = [
    limited(
      parser,
      post("Expect: 100-continue\r\nContent-Length: 16\r\n") + "b".repeat(15),
    ),
    limited(parser, "b"),
  ]
  inspect(
    steps.join("\n"),
    content=(
      #|continue, need more
      #|POST /p body=16, need more
    ),
  )
}

///|
test "Expect: 100-continue is answered whatever the case, with a chunked body too, and also when the body came without waiting" {
  inspect(
    [
      limited(
        @http1.Parser(),
        post("Expect: 100-Continue\r\nTransfer-Encoding: chunked\r\n") +
        "5\r\nhello\r\n0\r\n\r\n",
      ),
      limited(
        @http1.Parser(),
        post("Content-Length: 5\r\nEXPECT: 100-CONTINUE\r\n") +
        "hello" +
        post("Content-Length: 2\r\n") +
        "hi",
      ),
    ].join("\n"),
    content=(
      #|continue, POST /p body=5, need more
      #|continue, POST /p body=5, POST /p body=2, need more
    ),
  )
}

///|
test "Expect: 100-continue with a declared body length over the body limit gets 413, without 100 Continue" {
  inspect(
    limited(
      @http1.Parser(body_limit=16),
      post("Expect: 100-continue\r\nContent-Length: 17\r\n"),
    ),
    content="invalid 413",
  )
}

///|
test "100 Continue is never asked for HTTP/1.0, for a request without a body, or for another expectation" {
  inspect(
    [
      limited(
        @http1.Parser(),
        "POST /p HTTP/1.0\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\nhello",
      ),
      limited(
        @http1.Parser(),
        post("Expect: 100-continue\r\nContent-Length: 0\r\n"),
      ),
      limited(@http1.Parser(), post("Expect: 100-continue\r\n")),
      limited(
        @http1.Parser(),
        post("Expect: 100-continued\r\nContent-Length: 5\r\n") + "hello",
      ),
    ].join("\n"),
    content=(
      #|POST /p body=5, need more
      #|POST /p body=0, need more
      #|POST /p body=0, need more
      #|POST /p body=5, need more
    ),
  )
}

///|
test "100 Continue is asked for at the same point however the request is split" {
  let stream = @utf8.encode(
    post("Expect: 100-continue\r\nContent-Length: 5\r\n") +
    "hello" +
    post("Expect: 100-continue\r\nTransfer-Encoding: chunked\r\n") +
    "2\r\nhi\r\n0\r\n\r\n",
  )
  let steps = (0)
    .until(stream.length(), inclusive=true)
    .map(i => {
      let parser = @http1.Parser()
      let first = limited(parser, @utf8.decode_lossy(stream[:i]))
      let second = limited(parser, @utf8.decode_lossy(stream[i:]))
      "\{first}, \{second}"
      .replace_all(old="need more, ", new="")
      .replace_all(old=", need more", new="")
    })
    .collect()
  let distinct : Map[String, Unit] = Map([])
  for step in steps {
    distinct[step] = ()
  }
  debug_inspect(
    distinct.keys().collect(),
    content=(
      #|["continue, POST /p body=5, continue, POST /p body=2"]
    ),
  )
}
