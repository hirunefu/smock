// The connection policy, limits and timeouts on the wire: exact bytes sent
// to the smock binary over raw connections, on the plain port and on the
// TLS port.

///|
/// A Stub that answers `/users/1` whatever the method.
let any_method : String =
  #|{
  #|  "mocks": [{ "name": "users" }],
  #|  "stubs": [
  #|    {
  #|      "id": "user",
  #|      "mock": "users",
  #|      "request": { "path": "/users/1" },
  #|      "response": {
  #|        "status": 200,
  #|        "headers": { "Content-Type": "application/json" },
  #|        "body": "{\"id\":1,\"name\":\"Alice\"}"
  #|      }
  #|    }
  #|  ]
  #|}

///|
/// The log lines of a smock process, serving both ports, that wrote nothing
/// between starting and draining when it was stopped.
let startup_only : String =
  #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
  #|{"level":"info","msg":"random seed","seed":"*"}
  #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
  #|{"level":"info","msg":"state byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
  #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
  #|{"level":"info","msg":"listening","listener":"plain","address":"0.0.0.0:*"}
  #|{"level":"info","msg":"listening","listener":"tls","address":"0.0.0.0:*","certFile":"*/rsa-chain.pem","keyFile":"*/rsa-key.pem"}
  #|{"level":"info","msg":"drain started","timeoutMs":20000}
  #|{"level":"info","msg":"drain ended","connectionsCut":0}

///|
/// Reads a response head without a body, as sent for HEAD or for a 1xx
/// status, and renders it with `\r\n` shown as `\n`, without the empty line
/// that ends it.
async fn read_head(conn : Conn) -> String {
  let result = @async.with_timeout_opt(patience_ms, () => {
    conn.read_until("\r\n\r\n")
  })
  guard result is Some(head) else { fail("no response head in time") }
  match head {
    Some(head) => head.replace_all(old="\r\n", new="\n") + "\n"
    None => "closed"
  }
}

///|
/// The status line of `response`, as `read_response` renders it.
fn status_line(response : String) -> String {
  response[:response.find("\n").unwrap_or(response.length())].to_owned()
}

///|
/// Waits until smock ends the connection, and returns how many milliseconds
/// after `since` that was and what smock sent until then. A reset ends the
/// connection too.
async fn ended(conn : Conn, since : Int64) -> (Int64, String) {
  let (_, end, received) = received_until_end(conn, since)
  (end, @utf8.decode_lossy(received))
}

///|
async test "keep-alive: HTTP/1.1 keeps the connection open unless the request says Connection: close; HTTP/1.0 closes it unless the request says Connection: keep-alive" {
  let _ = on_both_ports(files=[("users.json", any_method)], (smock, over) => {
    let out = []
    let http11 = smock.connect(over~)
    defer http11.close()
    http11.write("GET /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n")
    out.push(read_response(http11))
    http11.write(
      "GET /users/1 HTTP/1.1\r\nHost: localhost\r\nConnection: Keep-Alive\r\n\r\n",
    )
    out.push(read_response(http11))
    http11.write(
      "GET /users/1 HTTP/1.1\r\nHost: localhost\r\nConnection: CLOSE\r\n\r\n",
    )
    out.push(read_response(http11))
    out.push(if closed(http11) { "(closed)" } else { "(open)" })
    let http10 = smock.connect(over~)
    defer http10.close()
    http10.write("GET /users/1 HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")
    out.push(read_response(http10))
    http10.write("GET /users/1 HTTP/1.0\r\nConnection: KEEP-ALIVE\r\n\r\n")
    out.push(read_response(http10))
    http10.write("GET /users/1 HTTP/1.0\r\n\r\n")
    out.push(read_response(http10))
    out.push(if closed(http10) { "(closed)" } else { "(open)" })
    inspect(
      out.join("\n---\n"),
      content=(
        #|HTTP/1.1 200 OK
        #|Content-Type: application/json
        #|Smock-Mock: users; via=default
        #|Content-Length: 23
        #|
        #|{"id":1,"name":"Alice"}
        #|---
        #|HTTP/1.1 200 OK
        #|Content-Type: application/json
        #|Smock-Mock: users; via=default
        #|Content-Length: 23
        #|
        #|{"id":1,"name":"Alice"}
        #|---
        #|HTTP/1.1 200 OK
        #|Content-Type: application/json
        #|Smock-Mock: users; via=default
        #|Connection: close
        #|Content-Length: 23
        #|
        #|{"id":1,"name":"Alice"}
        #|---
        #|(closed)
        #|---
        #|HTTP/1.1 200 OK
        #|Content-Type: application/json
        #|Smock-Mock: users; via=default
        #|Connection: keep-alive
        #|Content-Length: 23
        #|
        #|{"id":1,"name":"Alice"}
        #|---
        #|HTTP/1.1 200 OK
        #|Content-Type: application/json
        #|Smock-Mock: users; via=default
        #|Connection: keep-alive
        #|Content-Length: 23
        #|
        #|{"id":1,"name":"Alice"}
        #|---
        #|HTTP/1.1 200 OK
        #|Content-Type: application/json
        #|Smock-Mock: users; via=default
        #|Connection: close
        #|Content-Length: 23
        #|
        #|{"id":1,"name":"Alice"}
        #|---
        #|(closed)
      ),
    )
  })
}

///|
async test "a pipelined request that says Connection: close is answered, then the connection closes; the requests pipelined after it get no response" {
  let _ = on_both_ports(files=[("users.json", any_method)], (smock, over) => {
    let conn = smock.connect(over~)
    defer conn.close()
    conn.write(
      "GET /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n" +
      "GET /users/2 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" +
      "GET /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n" +
      "GET /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n",
    )
    let first = read_response(conn)
    let second = read_response(conn)
    let (_, rest) = ended(conn, @async.now())
    inspect(
      "\{status_line(first)}\n---\n\{second}\n---\nthen \{rest.escape()} and closed",
      content=(
        #|HTTP/1.1 200 OK
        #|---
        #|HTTP/1.1 404 Not Found
        #|Content-Type: application/json
        #|Smock-Near-Miss: user; failed=path
        #|Smock-Mock: users; via=default
        #|Connection: close
        #|Content-Length: 27
        #|
        #|{"error":"no Stub matched"}
        #|---
        #|then "" and closed
      ),
    )
  })
}

///|
async test "HEAD: the response carries its status and headers, with the Content-Length its body would have, but no body; the next request on the connection is answered as usual" {
  let _ = on_both_ports(files=[("users.json", any_method)], (smock, over) => {
    let conn = smock.connect(over~)
    defer conn.close()
    conn.write(
      "HEAD /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n" +
      "GET /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n" +
      "HEAD /users/2 HTTP/1.1\r\nHost: localhost\r\n\r\n" +
      "HEAD /users/1 HTTP/1.0\r\n\r\n",
    )
    let out = [
      read_head(conn),
      read_response(conn),
      read_head(conn),
      read_head(conn),
    ]
    let (_, rest) = ended(conn, @async.now())
    out.push("then \{rest.escape()} and closed")
    inspect(
      out.join("---\n"),
      content=(
        #|HTTP/1.1 200 OK
        #|Content-Type: application/json
        #|Smock-Mock: users; via=default
        #|Content-Length: 23
        #|---
        #|HTTP/1.1 200 OK
        #|Content-Type: application/json
        #|Smock-Mock: users; via=default
        #|Content-Length: 23
        #|
        #|{"id":1,"name":"Alice"}---
        #|HTTP/1.1 404 Not Found
        #|Content-Type: application/json
        #|Smock-Near-Miss: user; failed=path
        #|Smock-Mock: users; via=default
        #|Content-Length: 27
        #|---
        #|HTTP/1.1 200 OK
        #|Content-Type: application/json
        #|Smock-Mock: users; via=default
        #|Connection: close
        #|Content-Length: 23
        #|---
        #|then "" and closed
      ),
    )
  })
}

///|
async test "Expect: 100-continue within the body limit gets 100 Continue before the body is sent, then the final response; over the limit it gets 413 without the body, and the connection closes" {
  let _ = on_both_ports(
    files=[("users.json", any_method)],
    args=["--body-limit", "16"],
    (smock, over) => {
      let out = []
      let conn = smock.connect(over~)
      defer conn.close()
      conn.write(
        "POST /users/1 HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\nContent-Length: 16\r\n\r\n",
      )
      // smock answers before the body is sent.
      out.push(read_head(conn))
      conn.write("0123456789abcdef")
      out.push(status_line(read_response(conn)))
      // The connection stays open for the next request.
      conn.write("GET /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n")
      out.push(status_line(read_response(conn)))
      let over = smock.connect(over~)
      defer over.close()
      over.write(
        "POST /users/1 HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\nContent-Length: 17\r\n\r\n",
      )
      out.push(read_response(over))
      out.push(if closed(over) { "(closed)" } else { "(open)" })
      inspect(
        out.join("\n---\n"),
        content=(
          #|HTTP/1.1 100 Continue
          #|
          #|---
          #|HTTP/1.1 200 OK
          #|---
          #|HTTP/1.1 200 OK
          #|---
          #|HTTP/1.1 413 Content Too Large
          #|Connection: close
          #|Content-Length: 0
          #|
          #|
          #|---
          #|(closed)
        ),
      )
    },
  )
}

///|
async test "HTTP/1.0 never gets 100 Continue, and a client that sends its body without waiting for 100 Continue gets one final response" {
  let _ = on_both_ports(files=[("users.json", any_method)], (smock, over) => {
    let out = []
    let http10 = smock.connect(over~)
    defer http10.close()
    http10.write(
      "POST /users/1 HTTP/1.0\r\nConnection: keep-alive\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n",
    )
    @async.sleep(50)
    http10.write("hello")
    out.push(status_line(read_response(http10)))
    let eager = smock.connect(over~)
    defer eager.close()
    eager.write(
      "POST /users/1 HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\nhello",
    )
    // An interim 100 Continue may come first; then the one final response.
    let mut response = read_response(eager)
    if response.has_prefix("HTTP/1.1 100 ") {
      response = read_response(eager)
    }
    out.push(status_line(response))
    eager.write("GET /users/2 HTTP/1.1\r\nHost: localhost\r\n\r\n")
    out.push(status_line(read_response(eager)))
    inspect(
      out.join("\n"),
      content=(
        #|HTTP/1.1 200 OK
        #|HTTP/1.1 200 OK
        #|HTTP/1.1 404 Not Found
      ),
    )
  })
}

///|
/// A request head of exactly `size` bytes for `/users/1`.
fn head_of_size(size : Int) -> String {
  // "GET /users/1 HTTP/1.1\r\n" + "Host: localhost\r\n" + "X: " + padding +
  // "\r\n" + "\r\n"
  "GET /users/1 HTTP/1.1\r\nHost: localhost\r\nX: \{"p".repeat(size - 47)}\r\n\r\n"
}

///|
/// A request head for `/users/1` with `count` header fields.
fn head_with_fields(count : Int) -> String {
  let fields = (1).until(count).map(i => "X-\{i}: \{i}\r\n").collect()
  "GET /users/1 HTTP/1.1\r\nHost: localhost\r\n\{fields.join("")}\r\n"
}

///|
async test "limits: a head over the header size or header count limit gets 431, and a body over the body limit gets 413, then the connection closes; requests at the limits are answered" {
  let post = "POST /users/1 HTTP/1.1\r\nHost: localhost\r\n"
  let cases = [
    ("head of 128 bytes", head_of_size(128)),
    ("head of 129 bytes", head_of_size(129)),
    ("4 header fields", head_with_fields(4)),
    ("5 header fields", head_with_fields(5)),
    ("Content-Length: 16", "\{post}Content-Length: 16\r\n\r\n0123456789abcdef"),
    (
      "Content-Length: 17, without the body",
      "\{post}Content-Length: 17\r\n\r\n",
    ),
    (
      "chunked body of 16 bytes",
      "\{post}Transfer-Encoding: chunked\r\n\r\n10\r\n0123456789abcdef\r\n0\r\n\r\n",
    ),
    (
      "chunk taking the body to 17 bytes, without its data",
      "\{post}Transfer-Encoding: chunked\r\n\r\na\r\n0123456789\r\n7\r\n",
    ),
  ]
  let stopped = on_both_ports(
    files=[("users.json", any_method)],
    args=[
      "--header-size-limit", "128", "--header-count-limit", "4", "--body-limit",
      "16",
    ],
    (smock, over) => {
      let out = []
      for case in cases {
        let (name, bytes) = case
        let conn = smock.connect(over~)
        defer conn.close()
        conn.write(bytes)
        let response = read_response(conn)
        let after = if status_line(response).has_prefix("HTTP/1.1 200") {
          "open"
        } else {
          let (_, rest) = ended(conn, @async.now())
          "then \{rest.escape()} and closed"
        }
        out.push(
          "\{name}: \{response.trim_end(char_set="\n").replace_all(old="\n", new=" | ")}, \{after}",
        )
      }
      inspect(
        out.join("\n"),
        content=(
          #|head of 128 bytes: HTTP/1.1 200 OK | Content-Type: application/json | Smock-Mock: users; via=default | Content-Length: 23 |  | {"id":1,"name":"Alice"}, open
          #|head of 129 bytes: HTTP/1.1 431 Request Header Fields Too Large | Connection: close | Content-Length: 0, then "" and closed
          #|4 header fields: HTTP/1.1 200 OK | Content-Type: application/json | Smock-Mock: users; via=default | Content-Length: 23 |  | {"id":1,"name":"Alice"}, open
          #|5 header fields: HTTP/1.1 431 Request Header Fields Too Large | Connection: close | Content-Length: 0, then "" and closed
          #|Content-Length: 16: HTTP/1.1 200 OK | Content-Type: application/json | Smock-Mock: users; via=default | Content-Length: 23 |  | {"id":1,"name":"Alice"}, open
          #|Content-Length: 17, without the body: HTTP/1.1 413 Content Too Large | Connection: close | Content-Length: 0, then "" and closed
          #|chunked body of 16 bytes: HTTP/1.1 200 OK | Content-Type: application/json | Smock-Mock: users; via=default | Content-Length: 23 |  | {"id":1,"name":"Alice"}, open
          #|chunk taking the body to 17 bytes, without its data: HTTP/1.1 413 Content Too Large | Connection: close | Content-Length: 0, then "" and closed
        ),
      )
    },
  )
  // Requests that hit a limit are not logged one by one.
  inspect(log_entries(stopped.logs), content=startup_only)
}

///|
async test "read timeout: a request that has begun but has not all arrived within the read timeout ends the connection, even while its bytes keep coming" {
  let stopped = on_both_ports(
    files=[("users.json", any_method)],
    args=["--read-timeout-ms", "300", "--idle-timeout-ms", "10000"],
    (smock, over) => {
      let out = []
      // A head that stops halfway.
      let head = smock.connect(over~)
      defer head.close()
      let since = @async.now()
      head.write("GET /users/1 HTTP/1.1\r\nHost: local")
      let (elapsed, rest) = ended(head, since)
      out.push(
        "head cut short: \{rest.escape()}, ended after at least 300 ms: \{elapsed >= 300}",
      )
      // A body that stops halfway: the timeout covers the body too.
      let body = smock.connect(over~)
      defer body.close()
      let since = @async.now()
      body.write(
        "POST /users/1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\n01234",
      )
      let (elapsed, rest) = ended(body, since)
      out.push(
        "body cut short: \{rest.escape()}, ended after at least 300 ms: \{elapsed >= 300}",
      )
      // A request sent one byte every 50 ms would take over 2 s to arrive:
      // bytes keep coming, but the timeout runs from the first one.
      let slow = smock.connect(over~)
      defer slow.close()
      let request = @utf8.encode(
        "GET /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n",
      )
      let since = @async.now()
      @async.with_task_group(group => {
        group.spawn_bg(no_wait=true, () => {
          for i in 0..<request.length() {
            slow.write(request[i:i + 1]) catch {
              _ => return
            }
            @async.sleep(50)
          }
        })
        let (elapsed, rest) = ended(slow, since)
        out.push(
          "trickled: \{rest.escape()}, ended after at least 300 ms: \{elapsed >= 300}, before the request could arrive: \{elapsed < 2000}",
        )
      })
      // A request that arrives in time is answered.
      let in_time = smock.connect(over~)
      defer in_time.close()
      in_time.write("GET /users/1 HTTP/1.1\r\n")
      @async.sleep(100)
      in_time.write("Host: localhost\r\n\r\n")
      out.push("in time: \{status_line(read_response(in_time))}")
      inspect(
        out.join("\n"),
        content=(
          #|head cut short: "", ended after at least 300 ms: true
          #|body cut short: "", ended after at least 300 ms: true
          #|trickled: "", ended after at least 300 ms: true, before the request could arrive: true
          #|in time: HTTP/1.1 200 OK
        ),
      )
    },
  )
  // Timeouts are not logged one by one.
  inspect(log_entries(stopped.logs), content=startup_only)
}

///|
async test "read timeout: a request pipelined behind a slow response has the read timeout from when that response is written, since smock reads nothing while it writes" {
  let defs =
    #|{ "mocks": [{ "name": "users" }],
    #|  "stubs": [
    #|    { "id": "slow", "mock": "users", "request": { "path": "/slow" },
    #|      "response": { "status": 200, "body": "slow" },
    #|      "fault": { "delay": { "fixed": 600 } } },
    #|    { "id": "user", "mock": "users", "request": { "path": "/users/1" },
    #|      "response": { "status": 200, "body": "Alice" } } ] }
  let stopped = on_both_ports(
    files=[("users.json", defs)],
    args=["--read-timeout-ms", "300", "--idle-timeout-ms", "10000"],
    (smock, over) => {
      let out = []
      // The next request begins in the same write as the slow one, and its
      // rest comes once the slow response, 600 ms later, is in.
      let rest_later = smock.connect(over~)
      defer rest_later.close()
      rest_later.write(
        "GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\nGET /users/1 HTTP/1.1\r\nHost: local",
      )
      out.push("slow: \{status_line(read_response(rest_later))}")
      rest_later.write("host\r\n\r\n")
      out.push("pipelined: \{status_line(read_response(rest_later))}")
      // A rest that never comes still ends the connection, the read timeout
      // after the slow response (give or take the time it takes to read).
      let no_rest = smock.connect(over~)
      defer no_rest.close()
      no_rest.write(
        "GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\nGET /users/1 HTTP/1.1\r\nHost: local",
      )
      let _ = read_response(no_rest)
      let since = @async.now()
      let (elapsed, rest) = ended(no_rest, since)
      out.push(
        "no rest: \{rest.escape()}, ended about 300 ms after the slow response: \{elapsed >= 200 && elapsed < 1000}",
      )
      inspect(
        out.join("\n"),
        content=(
          #|slow: HTTP/1.1 200 OK
          #|pipelined: HTTP/1.1 200 OK
          #|no rest: "", ended about 300 ms after the slow response: true
        ),
      )
    },
  )
  inspect(log_entries(stopped.logs), content=startup_only)
}

///|
async test "idle timeout: a connection that receives no request bytes for the idle timeout is closed, whether it is new or kept alive; requests within it keep the connection open" {
  let stopped = on_both_ports(
    files=[("users.json", any_method)],
    args=["--read-timeout-ms", "300", "--idle-timeout-ms", "1500"],
    (smock, over) => {
      let out = []
      // A new connection that never sends anything: the read timeout does
      // not apply to it. Each wait is timed from before smock can have
      // started its idle timeout, so that a scheduling delay cannot make it
      // look short.
      let since = @async.now()
      let silent = smock.connect(over~)
      defer silent.close()
      let (elapsed, rest) = ended(silent, since)
      out.push(
        "new and silent: \{rest.escape()}, ended after at least 1500 ms: \{elapsed >= 1500}",
      )
      // A kept-alive connection, after its response.
      let kept = smock.connect(over~)
      defer kept.close()
      let since = @async.now()
      kept.write("GET /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n")
      let response = read_response(kept)
      let (elapsed, rest) = ended(kept, since)
      out.push(
        "kept alive: \{status_line(response)}, then \{rest.escape()}, ended after at least 1500 ms: \{elapsed >= 1500}",
      )
      // Requests 300 ms apart, for longer than the idle timeout.
      let busy = smock.connect(over~)
      defer busy.close()
      let statuses = []
      for _ in 0..<7 {
        busy.write("GET /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n")
        statuses.push(status_line(read_response(busy)))
        @async.sleep(300)
      }
      out.push("busy: \{statuses.join(", ")}")
      inspect(
        out.join("\n"),
        content=(
          #|new and silent: "", ended after at least 1500 ms: true
          #|kept alive: HTTP/1.1 200 OK, then "", ended after at least 1500 ms: true
          #|busy: HTTP/1.1 200 OK, HTTP/1.1 200 OK, HTTP/1.1 200 OK, HTTP/1.1 200 OK, HTTP/1.1 200 OK, HTTP/1.1 200 OK, HTTP/1.1 200 OK
        ),
      )
    },
  )
  inspect(log_entries(stopped.logs), content=startup_only)
}

///|
/// A Mock whose `/slow` answers after a delay of 1000 ms and whose
/// `/events` streams three events over 1200 ms: both outlast the timeouts
/// of the test below.
let outlasting : String =
  #|{ "mocks": [{ "name": "users" }],
  #|  "stubs": [
  #|    { "id": "slow", "mock": "users", "request": { "path": "/slow" },
  #|      "response": { "status": 200, "body": "slow" },
  #|      "fault": { "delay": { "fixed": 1000 } } },
  #|    { "id": "stream", "mock": "users", "request": { "path": "/events" },
  #|      "response": { "status": 200,
  #|        "events": [
  #|          { "delay": 400, "data": "first" },
  #|          { "delay": 400, "data": "second" },
  #|          { "delay": 400, "data": "last" } ] } } ] }

///|
async test "timeouts: neither timeout runs while smock writes a response, however long it takes; the idle timeout starts after it" {
  let stopped = on_both_ports(
    files=[("users.json", outlasting)],
    args=["--read-timeout-ms", "300", "--idle-timeout-ms", "500"],
    (smock, over) => {
      let out = []
      // A response delayed past both timeouts, on a connection that then
      // stays open for the idle timeout.
      let delayed = smock.connect(over~)
      defer delayed.close()
      delayed.write("GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n")
      let response = read_response(delayed)
      let since = @async.now()
      let (elapsed, rest) = ended(delayed, since)
      out.push(
        "delayed: \{response.escape()}, then \{rest.escape()}, ended about 500 ms after it: \{elapsed >= 300 && elapsed < 2000}",
      )
      // A stream longer than both timeouts.
      let stream = smock.connect(over~)
      defer stream.close()
      stream.write(
        "GET /events HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
      )
      let (_, streamed) = ended(stream, @async.now())
      out.push("streamed: \{streamed.escape()}")
      inspect(
        out.join("\n"),
        content=(
          #|delayed: "HTTP/1.1 200 OK\nSmock-Mock: users; via=default\nContent-Length: 4\n\nslow", then "", ended about 500 ms after it: true
          #|streamed: "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nSmock-Mock: users; via=default\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\nd\r\ndata: first\n\n\r\ne\r\ndata: second\n\n\r\nc\r\ndata: last\n\n\r\n0\r\n\r\n"
        ),
      )
    },
  )
  // Timeouts are not logged one by one.
  inspect(log_entries(stopped.logs), content=startup_only)
}

///|
async test "timeouts: a read timeout longer than the idle timeout gives a request that has begun the whole read timeout to arrive" {
  let stopped = on_both_ports(
    files=[("users.json", any_method)],
    args=["--read-timeout-ms", "1500", "--idle-timeout-ms", "300"],
    (smock, over) => {
      let out = []
      let conn = smock.connect(over~)
      defer conn.close()
      conn.write("GET /users/1 HTTP/1.1\r\n")
      @async.sleep(800)
      conn.write("Host: localhost\r\n\r\n")
      out.push("the rest 800 ms later: \{status_line(read_response(conn))}")
      let since = @async.now()
      conn.write("GET /users/1 HTTP/1.1\r\nHost: local")
      let (elapsed, rest) = ended(conn, since)
      out.push(
        "a rest that never comes: \{rest.escape()}, ended after at least 1500 ms: \{elapsed >= 1500}, before 3000 ms: \{elapsed < 3000}",
      )
      inspect(
        out.join("\n"),
        content=(
          #|the rest 800 ms later: HTTP/1.1 200 OK
          #|a rest that never comes: "", ended after at least 1500 ms: true, before 3000 ms: true
        ),
      )
    },
  )
  inspect(log_entries(stopped.logs), content=startup_only)
}
