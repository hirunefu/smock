// The Date field on the wire: every final response smock writes carries the
// current time, on the plain, the TLS and the admin port, unless a Stub or
// a Mock's noMatch.headers gives a Date of its own.

///|
/// A Mock with a Stub of each body kind: inline, from a body file, and a
/// stream of Server-Sent Events.
let dated : String =
  #|{ "mocks": [{ "name": "dated" }],
  #|  "stubs": [
  #|    { "id": "inline", "mock": "dated", "request": { "path": "/inline" },
  #|      "response": { "status": 200, "body": "inline" } },
  #|    { "id": "file", "mock": "dated", "request": { "path": "/file" },
  #|      "response": { "status": 200, "bodyFile": "hello.txt" } },
  #|    { "id": "events", "mock": "dated", "request": { "path": "/events" },
  #|      "response": { "status": 200, "events": [{ "data": "hi" }] } } ] }

///|
async test "every response on the plain and the TLS port carries one Date, the current time: a Stub's, a body file's, the head of an event stream, the no-match 404 and a 400 that smock sends itself" {
  let out = []
  let _ = on_both_ports(
    files=[("dated.json", dated), ("files/hello.txt", "from a file")],
    (smock, over) => {
      let requests = ["/inline", "/file", "/events", "/none"].map(path => {
        "GET \{path} HTTP/1.1\r\nHost: localhost\r\n\r\n"
      })
      // Whitespace before a colon gets 400.
      requests.push("GET /inline HTTP/1.1\r\nHost : localhost\r\n\r\n")
      for request in requests {
        let conn = smock.connect(over~)
        defer conn.close()
        conn.write(request)
        out.push(read_response(conn))
      }
    },
  )
  inspect(
    out.join("---\n"),
    content=(
      #|HTTP/1.1 200 OK
      #|Smock-Mock: dated; via=default
      #|Date: <now>
      #|Content-Length: 6
      #|
      #|inline---
      #|HTTP/1.1 200 OK
      #|Accept-Ranges: bytes
      #|Smock-Mock: dated; via=default
      #|Date: <now>
      #|Content-Length: 11
      #|
      #|from a file---
      #|HTTP/1.1 200 OK
      #|Content-Type: text/event-stream
      #|Smock-Mock: dated; via=default
      #|Date: <now>
      #|Transfer-Encoding: chunked
      #|
      #|---
      #|HTTP/1.1 404 Not Found
      #|Content-Type: application/json
      #|Smock-Near-Miss: inline; failed=path
      #|Smock-Mock: dated; via=default
      #|Date: <now>
      #|Content-Length: 27
      #|
      #|{"error":"no Stub matched"}---
      #|HTTP/1.1 400 Bad Request
      #|Date: <now>
      #|Connection: close
      #|Content-Length: 0
      #|
      #|---
      #|HTTP/1.1 200 OK
      #|Smock-Mock: dated; via=default
      #|Date: <now>
      #|Content-Length: 6
      #|
      #|inline---
      #|HTTP/1.1 200 OK
      #|Accept-Ranges: bytes
      #|Smock-Mock: dated; via=default
      #|Date: <now>
      #|Content-Length: 11
      #|
      #|from a file---
      #|HTTP/1.1 200 OK
      #|Content-Type: text/event-stream
      #|Smock-Mock: dated; via=default
      #|Date: <now>
      #|Transfer-Encoding: chunked
      #|
      #|---
      #|HTTP/1.1 404 Not Found
      #|Content-Type: application/json
      #|Smock-Near-Miss: inline; failed=path
      #|Smock-Mock: dated; via=default
      #|Date: <now>
      #|Content-Length: 27
      #|
      #|{"error":"no Stub matched"}---
      #|HTTP/1.1 400 Bad Request
      #|Date: <now>
      #|Connection: close
      #|Content-Length: 0
      #|
      #|
    ),
  )
}

///|
async test "every Admin API response carries one Date, the current time, errors and a 400 that smock sends itself included" {
  let _ = with_smock(["--port", "0"], smock => {
    let out = []
    for
      response in [
        smock.admin("GET", "/v1/status"),
        smock.admin("GET", "/v1/nowhere"),
        smock.admin("GET", "/v1/status", token=None),
      ] {
      let dates = response.headers.filter(header => {
        header.0.to_lower() == "date"
      })
      out.push(
        "\{response.status}: " +
        mask_date(dates.map(header => "\{header.0}: \{header.1}").join(", ")),
      )
    }
    let conn = PlainConn(
      @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:\{smock.admin_port}")),
    )
    defer conn.close()
    conn.write("GET /v1/status HTTP/1.1\r\nHost : localhost\r\n\r\n")
    let rejected = read_response(conn)
    out.push(rejected[:rejected.find("\n").unwrap()].to_owned())
    for line in rejected.split("\n") {
      if line.to_lower().has_prefix("date") {
        out.push(line.to_owned())
      }
    }
    inspect(
      out.join("\n"),
      content=(
        #|200: Date: <now>
        #|404: Date: <now>
        #|401: Date: <now>
        #|HTTP/1.1 400 Bad Request
        #|Date: <now>
      ),
    )
  })
}

///|
/// A Mock whose Stubs, CRUD Stub and noMatch.headers give their own Date,
/// each name in another case.
let own_dates : String =
  #|{ "mocks": [{ "name": "own",
  #|    "noMatch": { "headers": { "DaTe": "Sat, 01 Jan 2000 00:00:00 GMT" } } }],
  #|  "data": [{ "mock": "own", "name": "items", "key": "id", "json": [{ "id": 1 }] }],
  #|  "stubs": [
  #|    { "id": "lower", "mock": "own", "request": { "path": "/lower" },
  #|      "response": { "status": 200,
  #|        "headers": { "date": "Mon, 01 Jan 2001 00:00:00 GMT" },
  #|        "body": "lower" } },
  #|    { "id": "upper", "mock": "own", "request": { "path": "/upper" },
  #|      "response": { "status": 200,
  #|        "headers": { "DATE": "Tue, 02 Jan 2001 00:00:00 GMT" },
  #|        "events": [{ "data": "upper" }] } },
  #|    { "id": "title", "mock": "own", "request": { "path": "/title" },
  #|      "response": { "status": 200,
  #|        "headers": { "Date": "Wed, 03 Jan 2001 00:00:00 GMT" },
  #|        "bodyFile": "title.txt" } },
  #|    { "id": "items", "mock": "own",
  #|      "crud": { "bucket": "items", "path": "/items",
  #|        "headers": { "date": "Thu, 04 Jan 2001 00:00:00 GMT" } } } ] }

///|
async test "a Stub, a CRUD Stub or noMatch.headers that gives its own Date, in any case, gets exactly that one, and smock adds none" {
  let out = []
  let stopped = on_both_ports(
    files=[("own.json", own_dates), ("files/title.txt", "title")],
    (smock, over) => {
      for path in ["/lower", "/upper", "/title", "/items/1", "/none"] {
        let conn = smock.connect(over~)
        defer conn.close()
        conn.write("GET \{path} HTTP/1.1\r\nHost: localhost\r\n\r\n")
        out.push(read_response(conn))
      }
    },
  )
  inspect(stopped.status, content="0")
  inspect(
    out[:5].join("---\n"),
    content=(
      #|HTTP/1.1 200 OK
      #|date: Mon, 01 Jan 2001 00:00:00 GMT
      #|Smock-Mock: own; via=default
      #|Content-Length: 5
      #|
      #|lower---
      #|HTTP/1.1 200 OK
      #|Content-Type: text/event-stream
      #|DATE: Tue, 02 Jan 2001 00:00:00 GMT
      #|Smock-Mock: own; via=default
      #|Transfer-Encoding: chunked
      #|
      #|---
      #|HTTP/1.1 200 OK
      #|Date: Wed, 03 Jan 2001 00:00:00 GMT
      #|Accept-Ranges: bytes
      #|Smock-Mock: own; via=default
      #|Content-Length: 5
      #|
      #|title---
      #|HTTP/1.1 200 OK
      #|Content-Type: application/json
      #|date: Thu, 04 Jan 2001 00:00:00 GMT
      #|Smock-Mock: own; via=default
      #|Content-Length: 8
      #|
      #|{"id":1}---
      #|HTTP/1.1 404 Not Found
      #|Content-Type: application/json
      #|DaTe: Sat, 01 Jan 2000 00:00:00 GMT
      #|Smock-Near-Miss: lower; failed=path
      #|Smock-Mock: own; via=default
      #|Content-Length: 27
      #|
      #|{"error":"no Stub matched"}
    ),
  )
  // The TLS port answers the same.
  inspect(out[5:].join("---\n") == out[:5].join("---\n"), content="true")
}
