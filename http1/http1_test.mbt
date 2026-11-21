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
    Continue => "continue"
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
/// A request with the method `meth`, the target `target` and a field named
/// `name` after Host, then a field of 2,000 bytes.
fn padded_request(meth : String, target : String, name : String) -> String {
  "\{meth} \{target} HTTP/1.1\r\nHost: a.example\r\n\{name}: 1\r\nX-Pad: \{"p".repeat(2000)}\r\n\r\n"
}

///|
test "a method, target or field name that begins as the one of the request before it, with more or fewer characters, is read as sent, however the second request is cut" {
  // RFC 9112, section 3: a request line is the method, the request target
  // and the version; section 5.1: a field line begins with the field name.
  // The parser gives each as sent (the documentation of Request and Header),
  // and the same requests however the bytes are split into pieces (Parser's
  // documentation). Here the one before is the same text with 1 to 16
  // characters more, or fewer. Each request carries a field of 2,000 bytes,
  // so the two do not fit together in the 4,096 bytes the parser's first
  // buffer holds: when the second arrives in a piece of its own, or cut
  // within its first lines, the parser moves its bytes to the front of the
  // buffer before it reads its head.
  let more = "0123456789abcdef"
  let wrong = []
  for count in 1..<=16 {
    let longer = more[:count].to_owned()
    for pair in [(longer, ""), ("", longer)] {
      let (before, after) = pair
      let sent = [
        ("GET" + before, "/items" + before, "X-Item" + before),
        ("GET" + after, "/items" + after, "X-Item" + after),
      ]
      let expected = sent.map(request => {
        let (meth, target, name) = request
        "\{meth} \{target} \{name}"
      })
      expected.push("need more")
      let first = padded_request(sent[0].0, sent[0].1, sent[0].2)
      let second = padded_request(sent[1].0, sent[1].1, sent[1].2)
      // Fed whole, then cut before the second request and at each byte of
      // its request line, its Host field and the field named after it.
      let lines = second.length() - 2000 - "X-Pad: \r\n\r\n".length()
      for cut in -1..<=lines {
        let pieces = if cut < 0 {
          [first + second]
        } else {
          [first + second[:cut].to_owned(), second[cut:].to_owned()]
        }
        let parser = @http1.Parser()
        let out = []
        for piece in pieces {
          parser.feed(@utf8.encode(piece))
          while parser.next() is Complete(request) {
            let name = if request.headers.length() > 1 {
              request.headers[1].name
            } else {
              "(none)"
            }
            out.push("\{request.meth} \{request.target} \{name}")
          }
        }
        out.push(render(parser.next()))
        if out != expected {
          wrong.push((count, before, cut, out))
        }
      }
    }
  }
  debug_inspect(wrong, content="[]")
}

///|
test "a request that sends again the method, the target or a header field of the request before it gets the very string or field given for that request" {
  // Parser's documentation: "On one connection, a request's method, target
  // and header fields that are the same as in the request before, field by
  // field in order, are the very strings and `Header`s of that request,
  // which `physical_equal` tells; a field with the same name in its place
  // but another value is a new `Header` with that request's very name. A
  // name is the same only in the same case, and a value is compared
  // without the white space around it." The server relies on it to decode
  // a field that a client sends with every request once per connection
  // (DecodedHeaders::of in server/server.mbt; d66c05fa). The maintainer
  // made it a promise of the interface on 2026-11-21 (#324).
  let stream = "GET /a HTTP/1.1\r\nHost: a.example\r\nAccept: */*\r\nX-Id: 1\r\n\r\n" +
    "GET /a HTTP/1.1\r\nHost: a.example\r\nAccept: */*\r\nX-Id: 1\r\n\r\n" +
    "GET /a HTTP/1.1\r\nHost: a.example\r\nAccept: */*\r\nX-Id: 2\r\n\r\n" +
    "GET /a HTTP/1.1\r\nHost: a.example\r\nAccept: */*\r\nX-Id: \t 2  \r\n\r\n" +
    "GET /b HTTP/1.1\r\nHost: a.example\r\nX-Id: 2\r\nAccept: */*\r\n\r\n" +
    "POST /b HTTP/1.1\r\nhost: a.example\r\nX-Id: 2\r\nAccept: */*\r\n\r\n" +
    "POST /b HTTP/1.1\r\nhost: a.example\r\n\r\n" +
    "POST /b HTTP/1.1\r\nhost: a.example\r\nX-New: 1\r\n\r\n"
  let parser = @http1.Parser()
  parser.feed(@utf8.encode(stream))
  let same_or_new = (same : Bool) => if same { "same" } else { "new" }
  let out = []
  let mut before : @http1.Request? = None
  while parser.next() is Complete(request) {
    let line = StringBuilder()
    line.write_string("\{request.meth} \{request.target}:")
    if before is Some(earlier) {
      line.write_string(
        " method \{same_or_new(physical_equal(request.meth, earlier.meth))}, target \{same_or_new(physical_equal(request.target, earlier.target))}, fields",
      )
      for i, field in request.headers {
        let kind = match earlier.headers.get(i) {
          Some(other) if physical_equal(field, other) => "same"
          Some(other) if physical_equal(field.name, other.name) => "same name"
          _ => "new"
        }
        line.write_string(" \{field.name}=\{kind}")
      }
    } else {
      line.write_string(" the first")
    }
    out.push(line.to_string())
    before = Some(request)
  }
  inspect(
    out.join("\n"),
    content=(
      #|GET /a: the first
      #|GET /a: method same, target same, fields Host=same Accept=same X-Id=same
      #|GET /a: method same, target same, fields Host=same Accept=same X-Id=same name
      #|GET /a: method same, target same, fields Host=same Accept=same X-Id=same
      #|GET /b: method same, target new, fields Host=same X-Id=new Accept=new
      #|POST /b: method new, target same, fields host=new X-Id=same Accept=same
      #|POST /b: method same, target same, fields host=same
      #|POST /b: method same, target same, fields host=same X-New=new
    ),
  )
}

///|
test "requests fed one byte at a time come out as when fed whole" {
  let stream = "GET /a HTTP/1.1\r\nHost: a.example\r\n\r\nPOST /b HTTP/1.1\r\nHost: a.example\r\nContent-Length: 4\r\n\r\n\r\n\r\nGET /c HTTP/1.1\r\nHost: a.example\r\n\r\n"
  let bytes = @utf8.encode(stream)
  let parser = @http1.Parser()
  let one_by_one = []
  for i in 0..<bytes.length() {
    parser.feed(bytes[i:i + 1])
    while parser.next() is Complete(req) {
      one_by_one.push(render(Complete(req)))
    }
  }
  inspect(
    one_by_one.join("\n") + "\n" + render(parser.next()),
    content=(
      #|GET /a HTTP/1.1 | Host: a.example | body="" | keep-alive
      #|POST /b HTTP/1.1 | Host: a.example | Content-Length: 4 | body="\r\n\r\n" | keep-alive
      #|GET /c HTTP/1.1 | Host: a.example | body="" | keep-alive
      #|need more
    ),
  )
  inspect(
    parse_all([stream]),
    content=(
      #|GET /a HTTP/1.1 | Host: a.example | body="" | keep-alive
      #|POST /b HTTP/1.1 | Host: a.example | Content-Length: 4 | body="\r\n\r\n" | keep-alive
      #|GET /c HTTP/1.1 | Host: a.example | body="" | keep-alive
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
test "empty lines before a request line are ignored" {
  inspect(
    parse_all([
      "\r\nGET /a HTTP/1.1\r\nHost: a\r\n\r\n", "POST /b HTTP/1.1\r\nHost: a\r\nContent-Length: 2\r\n\r\nok\r\n",
      "\r", "\n\r\nGET /c HTTP/1.1\r\nHost: a\r\n\r\n", "\r\n\n",
    ]),
    content=(
      #|GET /a HTTP/1.1 | Host: a | body="" | keep-alive
      #|need more
      #|POST /b HTTP/1.1 | Host: a | Content-Length: 2 | body="ok" | keep-alive
      #|need more
      #|need more
      #|GET /c HTTP/1.1 | Host: a | body="" | keep-alive
      #|need more
      #|invalid 400
      #|
    ),
  )
}

///|
test "other malformed request lines and header fields get 400" {
  let cases = [
    "GET  / HTTP/1.1\r\nHost: a\r\n\r\n", "GET /  HTTP/1.1\r\nHost: a\r\n\r\n", "GET\t/ HTTP/1.1\r\nHost: a\r\n\r\n",
    " GET / HTTP/1.1\r\nHost: a\r\n\r\n", "GET / HTTP/1.1 \r\nHost: a\r\n\r\n", "GET /\u{0} HTTP/1.1\r\nHost: a\r\n\r\n",
    "GET /é HTTP/1.1\r\nHost: a\r\n\r\n", "GET / http/1.1\r\nHost: a\r\n\r\n", "GET / HTTP/1.10\r\nHost: a\r\n\r\n",
    "GET / HTTP/1\r\nHost: a\r\n\r\n", "GET / HTTP/11.1\r\nHost: a\r\n\r\n", "GET / HTTP/1.a\r\nHost: a\r\n\r\n",
    "GET / HTTP/1.1\r\n Host: a\r\n\r\n", "GET / HTTP/1.1\r\nHost: a\r\nX\t: 1\r\n\r\n",
    "GET / HTTP/1.1\r\nHost: a\r\nX(Y: 1\r\n\r\n", "GET / HTTP/1.1\r\nHost: a\r\nX\u{80}: 1\r\n\r\n",
    "GET / HTTP/1.1\r\nHost: a\r\nX: 1\u{0}2\r\n\r\n", "GET / HTTP/1.1\r\nHost: a\rX: 1\r\n\r\n",
    "GET / HTTP/1.1\r\nHost: a\nX: 1\r\n\r\n", "GET / HTTP/1.1\nHost: a\r\n\r\n",
    "GET / HTTP/1.1\r\nHost: a\n\n", "GET / HTTP/1.1\r\nHost: a\r\n\n", "GET / HTTP/1.1\r\nHost: a\r\n\r\r\n",
    "GET / HTTP/1.0\r\nHost: a\r\nHost: b\r\n\r\n",
  ]
  inspect(
    cases
    .map(case => {
      "\{shown(case)} -> \{parse_all([case]).trim_end(char_set="\n").replace_all(old="\n", new=", ")}"
    })
    .join("\n"),
    content=(
      #|"GET  / HTTP/1.1\r\nHost: a\r\n\r\n" -> invalid 400
      #|"GET /  HTTP/1.1\r\nHost: a\r\n\r\n" -> invalid 400
      #|"GET\t/ HTTP/1.1\r\nHost: a\r\n\r\n" -> invalid 400
      #|" GET / HTTP/1.1\r\nHost: a\r\n\r\n" -> invalid 400
      #|"GET / HTTP/1.1 \r\nHost: a\r\n\r\n" -> invalid 400
      #|"GET /\u{00} HTTP/1.1\r\nHost: a\r\n\r\n" -> invalid 400
      #|"GET /\u{e9} HTTP/1.1\r\nHost: a\r\n\r\n" -> invalid 400
      #|"GET / http/1.1\r\nHost: a\r\n\r\n" -> invalid 400
      #|"GET / HTTP/1.10\r\nHost: a\r\n\r\n" -> invalid 400
      #|"GET / HTTP/1\r\nHost: a\r\n\r\n" -> invalid 400
      #|"GET / HTTP/11.1\r\nHost: a\r\n\r\n" -> invalid 400
      #|"GET / HTTP/1.a\r\nHost: a\r\n\r\n" -> invalid 400
      #|"GET / HTTP/1.1\r\n Host: a\r\n\r\n" -> invalid 400
      #|"GET / HTTP/1.1\r\nHost: a\r\nX\t: 1\r\n\r\n" -> invalid 400
      #|"GET / HTTP/1.1\r\nHost: a\r\nX(Y: 1\r\n\r\n" -> invalid 400
      #|"GET / HTTP/1.1\r\nHost: a\r\nX\u{80}: 1\r\n\r\n" -> invalid 400
      #|"GET / HTTP/1.1\r\nHost: a\r\nX: 1\u{00}2\r\n\r\n" -> invalid 400
      #|"GET / HTTP/1.1\r\nHost: a\rX: 1\r\n\r\n" -> invalid 400
      #|"GET / HTTP/1.1\r\nHost: a\nX: 1\r\n\r\n" -> invalid 400
      #|"GET / HTTP/1.1\nHost: a\r\n\r\n" -> invalid 400
      #|"GET / HTTP/1.1\r\nHost: a\n\n" -> invalid 400
      #|"GET / HTTP/1.1\r\nHost: a\r\n\n" -> invalid 400
      #|"GET / HTTP/1.1\r\nHost: a\r\n\r\r\n" -> invalid 400
      #|"GET / HTTP/1.0\r\nHost: a\r\nHost: b\r\n\r\n" -> invalid 400
    ),
  )
}

///|
/// What a parser makes of the first request in `stream`: `accepted`, or
/// `invalid <status>`.
fn first_verdict(stream : String) -> String {
  let parser = @http1.Parser()
  parser.feed(@utf8.encode(stream))
  match parser.next() {
    Complete(_) => "accepted"
    Invalid(status~) => "invalid \{status}"
    Continue | NeedMore => "incomplete"
  }
}

///|
test "a request target in one of the four forms of RFC 9112 is accepted; any other target, or one with a fragment, gets 400" {
  // Sent with OPTIONS, which takes every form but authority-form, which is
  // sent with CONNECT.
  let authority_form = [
    "a.example:443", "127.0.0.1:8080", "[::1]:80", "[v1.x]:80",
  ]
  let targets = [
    // origin-form, absolute-form, authority-form and asterisk-form
    "/", "/users/1?x=y", "/a|b^c", "http://a.example", "http://a.example:8080/x?y",
    "urn:a", "a.example:443", "127.0.0.1:8080", "[::1]:80", "[v1.x]:80", "*", // in none of them
     "users/1", "a", "?x", "127.0.0.1", "[::1]", "[::1:80", "a/b:80", "a@b:80", "1http://a/",
    "**", "*/", // with a fragment
     "/#frag", "/a?x#", "http://a.example/#x",
  ]
  inspect(
    targets
    .map(target => {
      let meth = if authority_form.contains(target) {
        "CONNECT"
      } else {
        "OPTIONS"
      }
      "\{target} -> \{first_verdict("\{meth} \{target} HTTP/1.1\r\nHost: a\r\n\r\n")}"
    })
    .join("\n"),
    content=(
      #|/ -> accepted
      #|/users/1?x=y -> accepted
      #|/a|b^c -> accepted
      #|http://a.example -> accepted
      #|http://a.example:8080/x?y -> accepted
      #|urn:a -> accepted
      #|a.example:443 -> accepted
      #|127.0.0.1:8080 -> accepted
      #|[::1]:80 -> accepted
      #|[v1.x]:80 -> accepted
      #|* -> accepted
      #|users/1 -> invalid 400
      #|a -> invalid 400
      #|?x -> invalid 400
      #|127.0.0.1 -> invalid 400
      #|[::1] -> invalid 400
      #|[::1:80 -> invalid 400
      #|a/b:80 -> invalid 400
      #|a@b:80 -> invalid 400
      #|1http://a/ -> invalid 400
      #|** -> invalid 400
      #|*/ -> invalid 400
      #|/#frag -> invalid 400
      #|/a?x# -> invalid 400
      #|http://a.example/#x -> invalid 400
    ),
  )
  // An absolute-form target is an absolute-URI (RFC 9112, section 3.2.2),
  // `scheme ":" hier-part` (RFC 3986, section 4.3), and a scheme is a
  // letter, then any letters, digits, `+`, `-` and `.` (RFC 3986, section
  // 3.1: `scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`). So a
  // scheme of one letter will do, and each of the others may come second;
  // an empty scheme, one that begins with another character, or one that
  // holds another, makes no absolute-URI, and the target is in no form.
  let schemes = [
    "a:x", "a1:x", "a+:x", "a-:x", "a.:x", ":x", ":/x", "1:x", "+a:x", "-a:x", ".a:x",
    "a_:x", "a~:x", "a%2B:x",
  ]
  inspect(
    schemes
    .map(target => {
      "\{target} -> \{first_verdict("OPTIONS \{target} HTTP/1.1\r\nHost: a\r\n\r\n")}"
    })
    .join("\n"),
    content=(
      #|a:x -> accepted
      #|a1:x -> accepted
      #|a+:x -> accepted
      #|a-:x -> accepted
      #|a.:x -> accepted
      #|:x -> invalid 400
      #|:/x -> invalid 400
      #|1:x -> invalid 400
      #|+a:x -> invalid 400
      #|-a:x -> invalid 400
      #|.a:x -> invalid 400
      #|a_:x -> invalid 400
      #|a~:x -> invalid 400
      #|a%2B:x -> invalid 400
    ),
  )
}

///|
test "asterisk-form is only for OPTIONS and authority-form only for CONNECT, which takes no other form; a target in the wrong form gets 400" {
  let requests = [
    ("OPTIONS", "*"),
    ("GET", "*"),
    ("POST", "*"),
    ("CONNECT", "*"),
    ("options", "*"),
    ("CONNECT", "a.example:443"),
    ("CONNECT", "127.0.0.1:8080"),
    ("CONNECT", "[::1]:80"),
    ("GET", "a.example:443"),
    ("OPTIONS", "a.example:443"),
    ("GET", "127.0.0.1:80"),
    ("POST", "[::1]:80"),
    ("connect", "a.example:443"),
    ("CONNECT", "/"),
    ("CONNECT", "http://a.example:443/"),
    ("CONNECT", "a.example"),
    ("GET", "/"),
    ("OPTIONS", "/"),
    ("GET", "http://a.example/"),
    ("GET", "urn:a"),
  ]
  inspect(
    requests
    .map(request => {
      let (meth, target) = request
      "\{meth} \{target} -> \{first_verdict("\{meth} \{target} HTTP/1.1\r\nHost: a\r\n\r\n")}"
    })
    .join("\n"),
    content=(
      #|OPTIONS * -> accepted
      #|GET * -> invalid 400
      #|POST * -> invalid 400
      #|CONNECT * -> invalid 400
      #|options * -> invalid 400
      #|CONNECT a.example:443 -> accepted
      #|CONNECT 127.0.0.1:8080 -> accepted
      #|CONNECT [::1]:80 -> accepted
      #|GET a.example:443 -> invalid 400
      #|OPTIONS a.example:443 -> invalid 400
      #|GET 127.0.0.1:80 -> invalid 400
      #|POST [::1]:80 -> invalid 400
      #|connect a.example:443 -> invalid 400
      #|CONNECT / -> invalid 400
      #|CONNECT http://a.example:443/ -> invalid 400
      #|CONNECT a.example -> invalid 400
      #|GET / -> accepted
      #|OPTIONS / -> accepted
      #|GET http://a.example/ -> accepted
      #|GET urn:a -> accepted
    ),
  )
}

///|
test "a Host field whose value is not a host and an optional port gets 400" {
  let hosts = [
    // valid, including an empty value
    "a.example", "A.Example.:8080", "", "a.example:", "127.0.0.1:80", "a%2Db_~!$&'()*+,;=",
    "[::1]", "[::1]:8080", "[2001:db8::7]", "[1:2:3:4:5:6:7:8]", "[1:2:3:4:5:6:7::]",
    "[::ffff:192.0.2.1]", "[v7.a:b]", // not valid
     "a b", "a/b@c", "a@b", "a:b:80", "a:8o", "a%2", "a%zz", "[::1", "[::1]x", "[::1]:x",
    "[1:2:3:4:5:6:7:8:9]", "[1:2:3:4:5:6:7:8::]", "[::1::2]", "[12345::]", "[1.2.3.4]",
    "[::256.0.0.1]", "[::1.2.3.04]", "[v.a]", "[v7.]",
  ]
  inspect(
    hosts
    .map(host => {
      "\{shown(host)} -> \{first_verdict("GET / HTTP/1.1\r\nHost: \{host}\r\n\r\n")}"
    })
    .join("\n"),
    content=(
      #|"a.example" -> accepted
      #|"A.Example.:8080" -> accepted
      #|"" -> accepted
      #|"a.example:" -> accepted
      #|"127.0.0.1:80" -> accepted
      #|"a%2Db_~!$&'()*+,;=" -> accepted
      #|"[::1]" -> accepted
      #|"[::1]:8080" -> accepted
      #|"[2001:db8::7]" -> accepted
      #|"[1:2:3:4:5:6:7:8]" -> accepted
      #|"[1:2:3:4:5:6:7::]" -> accepted
      #|"[::ffff:192.0.2.1]" -> accepted
      #|"[v7.a:b]" -> accepted
      #|"a b" -> invalid 400
      #|"a/b@c" -> invalid 400
      #|"a@b" -> invalid 400
      #|"a:b:80" -> invalid 400
      #|"a:8o" -> invalid 400
      #|"a%2" -> invalid 400
      #|"a%zz" -> invalid 400
      #|"[::1" -> invalid 400
      #|"[::1]x" -> invalid 400
      #|"[::1]:x" -> invalid 400
      #|"[1:2:3:4:5:6:7:8:9]" -> invalid 400
      #|"[1:2:3:4:5:6:7:8::]" -> invalid 400
      #|"[::1::2]" -> invalid 400
      #|"[12345::]" -> invalid 400
      #|"[1.2.3.4]" -> invalid 400
      #|"[::256.0.0.1]" -> invalid 400
      #|"[::1.2.3.04]" -> invalid 400
      #|"[v.a]" -> invalid 400
      #|"[v7.]" -> invalid 400
    ),
  )
}

///|
test "a chunked body is decoded, and the request after it comes out next" {
  inspect(
    parse_all([
      "POST /a HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n7\r\n, world\r\n0\r\n\r\nGET /b HTTP/1.1\r\nHost: a\r\n\r\n",
    ]),
    content=(
      #|POST /a HTTP/1.1 | Host: a | Transfer-Encoding: chunked | body="hello, world" | keep-alive
      #|GET /b HTTP/1.1 | Host: a | body="" | keep-alive
      #|need more
      #|
    ),
  )
  // A chunk size is hexadecimal, `chunk-size = 1*HEXDIG` (RFC 9112, section
  // 7.1), and HEXDIG's letters are "A" to "F" (RFC 5234, appendix B.1),
  // which ABNF matches in either case (RFC 5234, section 2.3): A and a are
  // 10, F and f are 15.
  inspect(
    parse_all([
      "POST /a HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n" +
      "A\r\nabcdefghij\r\na\r\nklmnopqrst\r\nF\r\nABCDEFGHIJKLMNO\r\nf\r\nPQRSTUVWXYZ0123\r\n0\r\n\r\n" +
      "GET /b HTTP/1.1\r\nHost: a\r\n\r\n",
    ]),
    content=(
      #|POST /a HTTP/1.1 | Host: a | Transfer-Encoding: chunked | body="abcdefghijklmnopqrstABCDEFGHIJKLMNOPQRSTUVWXYZ0123" | keep-alive
      #|GET /b HTTP/1.1 | Host: a | body="" | keep-alive
      #|need more
      #|
    ),
  )
  // The CRLF that ends the chunked body (RFC 9112, section 7.1:
  // `chunked-body = *chunk last-chunk trailer-section CRLF`) ends it also
  // when its LF comes first in the next piece, before a request much longer
  // than all that came before it: however the bytes are split into pieces,
  // the parser takes out the same requests (Parser).
  let parser = @http1.Parser()
  inspect(
    [
      limited(
        parser,
        post("Transfer-Encoding: chunked\r\n") + "5\r\nhello\r\n0\r\n\r",
      ),
      limited(
        parser,
        "\n" + post("Content-Length: 65536\r\n") + "b".repeat(65536),
      ),
    ].join("\n"),
    content=(
      #|need more
      #|POST /p body=5, POST /p body=65536, need more
    ),
  )
}

///|
test "chunk extensions and trailer fields are accepted and ignored" {
  inspect(
    parse_all([
      "POST /a HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n" +
      "5;name\r\nhello\r\n" +
      "1 ; a = b ;c=\"quoted \\\" \\\\ ;=\"\t;d\r\n,\r\n" +
      "6;e=\"\"\r\n world\r\n" +
      "000;last=1\r\n" +
      "Checksum: abc\r\nX-Trailer:\t1 \r\n\r\n" +
      "GET /b HTTP/1.1\r\nHost: a\r\n\r\n",
    ]),
    content=(
      #|POST /a HTTP/1.1 | Host: a | Transfer-Encoding: chunked | body="hello, world" | keep-alive
      #|GET /b HTTP/1.1 | Host: a | body="" | keep-alive
      #|need more
      #|
    ),
  )
}

///|
/// `s` as a quoted, escaped string literal, with DEL and every character
/// beyond ASCII escaped too.
fn shown(s : String) -> String {
  let out = StringBuilder()
  for c in s.escape() {
    if c.to_int() >= 0x7f {
      out.write_string("\\u{\{c.to_int().to_string(radix=16)}}")
    } else {
      out.write_char(c)
    }
  }
  out.to_string()
}

///|
/// What a parser makes of a chunked request whose body is `body`, followed
/// by a request it must not reach when the body is broken.
fn chunked_outcome(body : String) -> String {
  parse_all([
    "POST /a HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n\{body}GET /b HTTP/1.1\r\nHost: a\r\n\r\n",
  ])
  .trim_end(char_set="\n")
  .split("\n")
  .map(line => {
    if line.has_prefix("POST") {
      "complete"
    } else {
      line.to_owned()
    }
  })
  .join(", ")
}

///|
test "a bad chunk size or broken chunk framing gets 400" {
  let cases = [
    "x\r\nhello\r\n0\r\n\r\n", "\r\nhello\r\n0\r\n\r\n", "-5\r\nhello\r\n0\r\n\r\n",
    "+5\r\nhello\r\n0\r\n\r\n", "0x5\r\nhello\r\n0\r\n\r\n", " 5\r\nhello\r\n0\r\n\r\n",
    "5 \r\nhello\r\n0\r\n\r\n", "5;\r\nhello\r\n0\r\n\r\n", "5;a=\r\nhello\r\n0\r\n\r\n",
    "5;a b\r\nhello\r\n0\r\n\r\n", "5;a=b c\r\nhello\r\n0\r\n\r\n", "5;a=\"b\r\nhello\r\n0\r\n\r\n",
    "5;a=\"b\"c\r\nhello\r\n0\r\n\r\n", "5;a=\"\\\r\"\r\nhello\r\n0\r\n\r\n", "5;a=b\u{0}\r\nhello\r\n0\r\n\r\n",
    "5\nhello\r\n0\r\n\r\n", "5\rhello\r\n0\r\n\r\n", "5\r\nhelloX\r\n0\r\n\r\n",
    "5\r\nhel\r\n0\r\n\r\n", "5\r\nhello\n0\r\n\r\n", "5\r\nhello0\r\n\r\n", "0\r\n\n",
    "0\r\n\r\r\n", "0\nX: 1\r\n\r\n", "0\r\nX : 1\r\n\r\n", "0\r\n folded\r\n\r\n",
    "0\r\nX: 1\r\n folded\r\n\r\n", "0\r\nX\r\n\r\n", "0\r\n: 1\r\n\r\n", "0\r\nX: \u{7f}\r\n\r\n",
    "0\r\nX: 1\n\r\n",
  ]
  inspect(
    cases.map(case => "\{shown(case)} -> \{chunked_outcome(case)}").join("\n"),
    content=(
      #|"x\r\nhello\r\n0\r\n\r\n" -> invalid 400
      #|"\r\nhello\r\n0\r\n\r\n" -> invalid 400
      #|"-5\r\nhello\r\n0\r\n\r\n" -> invalid 400
      #|"+5\r\nhello\r\n0\r\n\r\n" -> invalid 400
      #|"0x5\r\nhello\r\n0\r\n\r\n" -> invalid 400
      #|" 5\r\nhello\r\n0\r\n\r\n" -> invalid 400
      #|"5 \r\nhello\r\n0\r\n\r\n" -> invalid 400
      #|"5;\r\nhello\r\n0\r\n\r\n" -> invalid 400
      #|"5;a=\r\nhello\r\n0\r\n\r\n" -> invalid 400
      #|"5;a b\r\nhello\r\n0\r\n\r\n" -> invalid 400
      #|"5;a=b c\r\nhello\r\n0\r\n\r\n" -> invalid 400
      #|"5;a=\"b\r\nhello\r\n0\r\n\r\n" -> invalid 400
      #|"5;a=\"b\"c\r\nhello\r\n0\r\n\r\n" -> invalid 400
      #|"5;a=\"\\\r\"\r\nhello\r\n0\r\n\r\n" -> invalid 400
      #|"5;a=b\u{00}\r\nhello\r\n0\r\n\r\n" -> invalid 400
      #|"5\nhello\r\n0\r\n\r\n" -> invalid 400
      #|"5\rhello\r\n0\r\n\r\n" -> invalid 400
      #|"5\r\nhelloX\r\n0\r\n\r\n" -> invalid 400
      #|"5\r\nhel\r\n0\r\n\r\n" -> invalid 400
      #|"5\r\nhello\n0\r\n\r\n" -> invalid 400
      #|"5\r\nhello0\r\n\r\n" -> invalid 400
      #|"0\r\n\n" -> invalid 400
      #|"0\r\n\r\r\n" -> invalid 400
      #|"0\nX: 1\r\n\r\n" -> invalid 400
      #|"0\r\nX : 1\r\n\r\n" -> invalid 400
      #|"0\r\n folded\r\n\r\n" -> invalid 400
      #|"0\r\nX: 1\r\n folded\r\n\r\n" -> invalid 400
      #|"0\r\nX\r\n\r\n" -> invalid 400
      #|"0\r\n: 1\r\n\r\n" -> invalid 400
      #|"0\r\nX: \u{7f}\r\n\r\n" -> invalid 400
      #|"0\r\nX: 1\n\r\n" -> invalid 400
    ),
  )
  // Each CR and LF that ends a chunk's two lines replaced by another byte:
  // a chunk is `chunk-size [ chunk-ext ] CRLF chunk-data CRLF` (RFC 9112,
  // section 7.1), so each is broken chunk framing, which gets 400
  // (Parsed::Invalid), even though the bytes after it frame a body.
  let replaced = [
    "5X\nhello\r\n0\r\n\r\n", "5\rXhello\r\n0\r\n\r\n", "5\r\nhelloX\n0\r\n\r\n",
    "5\r\nhello\rX0\r\n\r\n",
  ]
  inspect(
    replaced
    .map(case => "\{shown(case)} -> \{chunked_outcome(case)}")
    .join("\n"),
    content=(
      #|"5X\nhello\r\n0\r\n\r\n" -> invalid 400
      #|"5\rXhello\r\n0\r\n\r\n" -> invalid 400
      #|"5\r\nhelloX\n0\r\n\r\n" -> invalid 400
      #|"5\r\nhello\rX0\r\n\r\n" -> invalid 400
    ),
  )
}

///|
test "a chunk size too large to hold gets 413; leading zeros are not too large" {
  inspect(
    [
      "80000000\r\n", "ffffffffffffffffffff\r\n", "000000000000000000000005\r\nhello\r\n0\r\n\r\n",
    ]
    .map(case => "\{shown(case)} -> \{chunked_outcome(case)}")
    .join("\n"),
    content=(
      #|"80000000\r\n" -> invalid 413
      #|"ffffffffffffffffffff\r\n" -> invalid 413
      #|"000000000000000000000005\r\nhello\r\n0\r\n\r\n" -> complete, GET /b HTTP/1.1 | Host: a | body="" | keep-alive, need more
    ),
  )
}

///|
/// What a parser makes of `POST /a` with the header fields `fields` and the
/// bytes `rest` after its head, followed by `GET /b`. The POST request is
/// shown with its body only.
fn framing_outcome(fields : String, rest : String) -> String {
  parse_all([
    "POST /a HTTP/1.1\r\nHost: a\r\n\{fields}\r\n\{rest}GET /b HTTP/1.1\r\nHost: a\r\n\r\n",
  ])
  .trim_end(char_set="\n")
  .split("\n")
  .map(line => {
    guard line.has_prefix("POST") else { line.to_owned() }
    line[line.find("body=").unwrap_or(0):].to_owned()
  })
  .join(", ")
}

///|
test "a request with both Content-Length and Transfer-Encoding gets 400" {
  let cases = [
    (
      "Content-Length: 5\r\nTransfer-Encoding: chunked\r\n", "5\r\nhello\r\n0\r\n\r\n",
    ),
    (
      "Transfer-Encoding: chunked\r\nContent-Length: 5\r\n", "5\r\nhello\r\n0\r\n\r\n",
    ),
    ("Transfer-Encoding: gzip\r\nContent-Length: 5\r\n", "hello"),
    ("Transfer-Encoding: \r\nContent-Length: 5\r\n", "hello"),
  ]
  inspect(
    cases
    .map(case => {
      let (fields, rest) = case
      "\{shown(fields)} -> \{framing_outcome(fields, rest)}"
    })
    .join("\n"),
    content=(
      #|"Content-Length: 5\r\nTransfer-Encoding: chunked\r\n" -> invalid 400
      #|"Transfer-Encoding: chunked\r\nContent-Length: 5\r\n" -> invalid 400
      #|"Transfer-Encoding: gzip\r\nContent-Length: 5\r\n" -> invalid 400
      #|"Transfer-Encoding: \r\nContent-Length: 5\r\n" -> invalid 400
    ),
  )
}

///|
test "chunked is the only transfer coding; any other gets 501, and chunked twice gets 400" {
  let body = "5\r\nhello\r\n0\r\n\r\n"
  let cases = [
    "Transfer-Encoding: Chunked\r\n", "Transfer-Encoding: , chunked ,\r\n", "Transfer-Encoding: gzip\r\n",
    "Transfer-Encoding: gzip, chunked\r\n", "Transfer-Encoding: chunked, gzip\r\n",
    "Transfer-Encoding: identity\r\n", "Transfer-Encoding: xchunked\r\n", "Transfer-Encoding: chunked;a=b\r\n",
    "Transfer-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n", "Transfer-Encoding: chunked, chunked\r\n",
    "Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n", "Transfer-Encoding: \r\n",
    "Transfer-Encoding: ,\r\n",
  ]
  inspect(
    cases
    .map(fields => "\{shown(fields)} -> \{framing_outcome(fields, body)}")
    .join("\n"),
    content=(
      #|"Transfer-Encoding: Chunked\r\n" -> body="hello" | keep-alive, GET /b HTTP/1.1 | Host: a | body="" | keep-alive, need more
      #|"Transfer-Encoding: , chunked ,\r\n" -> body="hello" | keep-alive, GET /b HTTP/1.1 | Host: a | body="" | keep-alive, need more
      #|"Transfer-Encoding: gzip\r\n" -> invalid 501
      #|"Transfer-Encoding: gzip, chunked\r\n" -> invalid 501
      #|"Transfer-Encoding: chunked, gzip\r\n" -> invalid 501
      #|"Transfer-Encoding: identity\r\n" -> invalid 501
      #|"Transfer-Encoding: xchunked\r\n" -> invalid 501
      #|"Transfer-Encoding: chunked;a=b\r\n" -> invalid 501
      #|"Transfer-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n" -> invalid 501
      #|"Transfer-Encoding: chunked, chunked\r\n" -> invalid 400
      #|"Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n" -> invalid 400
      #|"Transfer-Encoding: \r\n" -> invalid 400
      #|"Transfer-Encoding: ,\r\n" -> invalid 400
    ),
  )
}

///|
test "Content-Length values that disagree get 400; identical repeated values do not" {
  let cases = [
    "Content-Length: 5, 5\r\n", "Content-Length: 5\r\nContent-Length: 5\r\n", "Content-Length: 5 ,5\r\nContent-Length: 005\r\n",
    "Content-Length: 00000000000000000005\r\n", "Content-Length: 5, 6\r\n", "Content-Length: 5\r\nContent-Length: 6\r\n",
    "Content-Length: 5, 5\r\nContent-Length: 6\r\n", "Content-Length: 99999999999, 5\r\n",
    "Content-Length: 5\r\nContent-Length: 99999999999\r\n",
  ]
  inspect(
    cases
    .map(fields => "\{shown(fields)} -> \{framing_outcome(fields, "hello")}")
    .join("\n"),
    content=(
      #|"Content-Length: 5, 5\r\n" -> body="hello" | keep-alive, GET /b HTTP/1.1 | Host: a | body="" | keep-alive, need more
      #|"Content-Length: 5\r\nContent-Length: 5\r\n" -> body="hello" | keep-alive, GET /b HTTP/1.1 | Host: a | body="" | keep-alive, need more
      #|"Content-Length: 5 ,5\r\nContent-Length: 005\r\n" -> body="hello" | keep-alive, GET /b HTTP/1.1 | Host: a | body="" | keep-alive, need more
      #|"Content-Length: 00000000000000000005\r\n" -> body="hello" | keep-alive, GET /b HTTP/1.1 | Host: a | body="" | keep-alive, need more
      #|"Content-Length: 5, 6\r\n" -> invalid 400
      #|"Content-Length: 5\r\nContent-Length: 6\r\n" -> invalid 400
      #|"Content-Length: 5, 5\r\nContent-Length: 6\r\n" -> invalid 400
      #|"Content-Length: 99999999999, 5\r\n" -> invalid 400
      #|"Content-Length: 5\r\nContent-Length: 99999999999\r\n" -> invalid 400
    ),
  )
}

///|
test "a Content-Length that is not a valid number gets 400; one too large to hold gets 413" {
  let cases = [
    "Content-Length: \r\n", "Content-Length: 5,\r\n", "Content-Length: ,5\r\n", "Content-Length: +5\r\n",
    "Content-Length: -5\r\n", "Content-Length: 0x5\r\n", "Content-Length: 5 5\r\n",
    "Content-Length: 5.0\r\n", "Content-Length: 5;q\r\n", "Content-Length: \"5\"\r\n",
    "Content-Length: 99999999999\r\n", "Content-Length: 99999999999, 99999999999\r\n",
  ]
  inspect(
    cases
    .map(fields => "\{shown(fields)} -> \{framing_outcome(fields, "hello")}")
    .join("\n"),
    content=(
      #|"Content-Length: \r\n" -> invalid 400
      #|"Content-Length: 5,\r\n" -> invalid 400
      #|"Content-Length: ,5\r\n" -> invalid 400
      #|"Content-Length: +5\r\n" -> invalid 400
      #|"Content-Length: -5\r\n" -> invalid 400
      #|"Content-Length: 0x5\r\n" -> invalid 400
      #|"Content-Length: 5 5\r\n" -> invalid 400
      #|"Content-Length: 5.0\r\n" -> invalid 400
      #|"Content-Length: 5;q\r\n" -> invalid 400
      #|"Content-Length: \"5\"\r\n" -> invalid 400
      #|"Content-Length: 99999999999\r\n" -> invalid 413
      #|"Content-Length: 99999999999, 99999999999\r\n" -> invalid 413
    ),
  )
}

///|
test "a request line with an HTTP major version other than 1 gets 505; a later HTTP/1 minor version is read as HTTP/1.1" {
  let cases = [
    "GET / HTTP/2.0\r\nHost: a\r\n\r\n", "GET / HTTP/0.9\r\n\r\n", "GET / HTTP/3.1\r\nHost: a\r\n\r\n",
    "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", "GET / HTTP/1.2\r\nHost: a\r\n\r\n", "GET / HTTP/1.9\r\n\r\n",
  ]
  inspect(
    cases
    .map(case => {
      "\{shown(case)} -> \{parse_all([case]).trim_end(char_set="\n").replace_all(old="\n", new=", ")}"
    })
    .join("\n"),
    content=(
      #|"GET / HTTP/2.0\r\nHost: a\r\n\r\n" -> invalid 505
      #|"GET / HTTP/0.9\r\n\r\n" -> invalid 505
      #|"GET / HTTP/3.1\r\nHost: a\r\n\r\n" -> invalid 505
      #|"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" -> invalid 505
      #|"GET / HTTP/1.2\r\nHost: a\r\n\r\n" -> GET / HTTP/1.1 | Host: a | body="" | keep-alive, need more
      #|"GET / HTTP/1.9\r\n\r\n" -> invalid 400
    ),
  )
}

///|
test "an HTTP/1.0 request with Transfer-Encoding gets 400, since its framing cannot be trusted" {
  inspect(
    parse_all([
      "POST /a HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
    ]),
    content=(
      #|invalid 400
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
