// HTTP/1.1 framing on the wire: exact bytes sent to the smock binary over
// raw connections, on the plain port and on the TLS port.

///|
/// Requests that use every framing smock reads: no body, a Content-Length
/// body and a chunked body with an extension and a trailer field. The
/// bodies hold bytes that look like a request.
let pipelined : String = "GET /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n" +
  "GET /users/2 HTTP/1.1\r\nHost: localhost\r\n\r\n" +
  "POST /users/1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 42\r\n\r\n" +
  "GET /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n" +
  "POST /users/1 HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" +
  "19;note=\"GET /\"\r\nGET /users/1 HTTP/1.1\r\n\r\n\r\n0\r\nX-Checksum: 1\r\n\r\n" +
  "GET /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n"

///|
/// The responses to `pipelined`, in order.
let pipelined_responses : String =
  #|HTTP/1.1 200 OK
  #|Content-Type: application/json
  #|X-Source: smock
  #|Smock-Mock: users; via=default
  #|Content-Length: 23
  #|
  #|{"id":1,"name":"Alice"}
  #|---
  #|HTTP/1.1 404 Not Found
  #|Content-Type: application/json
  #|Smock-Mock: users; via=default
  #|Content-Length: 27
  #|
  #|{"error":"no Stub matched"}
  #|---
  #|HTTP/1.1 404 Not Found
  #|Content-Type: application/json
  #|Smock-Mock: users; via=default
  #|Content-Length: 27
  #|
  #|{"error":"no Stub matched"}
  #|---
  #|HTTP/1.1 404 Not Found
  #|Content-Type: application/json
  #|Smock-Mock: users; via=default
  #|Content-Length: 27
  #|
  #|{"error":"no Stub matched"}
  #|---
  #|HTTP/1.1 200 OK
  #|Content-Type: application/json
  #|X-Source: smock
  #|Smock-Mock: users; via=default
  #|Content-Length: 23
  #|
  #|{"id":1,"name":"Alice"}

///|
/// Malformed or ambiguous framing, each sent after a valid request on the
/// same connection.
let rejected : Array[(String, Bytes)] = [
  (
    "Content-Length and Transfer-Encoding", b"POST /users/1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
  ),
  (
    "Content-Length values that disagree", b"POST /users/1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5, 6\r\n\r\nhello!",
  ),
  (
    "repeated Content-Length fields that disagree", b"POST /users/1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello!",
  ),
  (
    "a Content-Length that is not a number", b"POST /users/1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5x\r\n\r\nhello",
  ),
  (
    "a bad chunk size", b"POST /users/1 HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nhello\r\n0\r\n\r\n",
  ),
  (
    "broken chunk framing", b"POST /users/1 HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhelloXX\r\n0\r\n\r\n",
  ),
  (
    "a transfer coding other than chunked", b"POST /users/1 HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: gzip\r\n\r\n",
  ),
  ("HTTP/2.0", b"GET /users/1 HTTP/2.0\r\nHost: localhost\r\n\r\n"),
  (
    "whitespace before a colon", b"GET /users/1 HTTP/1.1\r\nHost : localhost\r\n\r\n",
  ),
  (
    "obsolete line folding", b"GET /users/1 HTTP/1.1\r\nHost: localhost\r\nX-A: 1\r\n folded\r\n\r\n",
  ),
  (
    "an invalid character in a field name", b"GET /users/1 HTTP/1.1\r\nHost: localhost\r\nX(A): 1\r\n\r\n",
  ),
  ("bare LF line ends", b"GET /users/1 HTTP/1.1\nHost: localhost\n\n"),
  ("a TLS handshake", b"\x16\x03\x01\x02\x00\x01\x00\x01\xfc\x03\x03"),
]

///|
async test "after malformed or ambiguous framing, smock answers what came before, then writes the error status with Connection: close and closes the connection" {
  let stopped = on_both_ports((smock, over) => {
    let outcomes = []
    for case in rejected {
      let (name, bytes) = case
      let conn = smock.connect(over~)
      defer conn.close()
      conn.write(
        @utf8.encode("GET /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n") + bytes,
      )
      let first = read_response(conn)
      let status_line = first[:first.find("\n").unwrap_or(0)]
      let error = read_response(conn)
        .trim_end(char_set="\n")
        .replace_all(old="\n", new=" | ")
      let end = if closed(conn) { "closed" } else { "open" }
      outcomes.push("\{name}: \{status_line}, then \{error}, then \{end}")
    }
    inspect(
      outcomes.join("\n"),
      content=(
        #|Content-Length and Transfer-Encoding: HTTP/1.1 200 OK, then HTTP/1.1 400 Bad Request | Connection: close | Content-Length: 0, then closed
        #|Content-Length values that disagree: HTTP/1.1 200 OK, then HTTP/1.1 400 Bad Request | Connection: close | Content-Length: 0, then closed
        #|repeated Content-Length fields that disagree: HTTP/1.1 200 OK, then HTTP/1.1 400 Bad Request | Connection: close | Content-Length: 0, then closed
        #|a Content-Length that is not a number: HTTP/1.1 200 OK, then HTTP/1.1 400 Bad Request | Connection: close | Content-Length: 0, then closed
        #|a bad chunk size: HTTP/1.1 200 OK, then HTTP/1.1 400 Bad Request | Connection: close | Content-Length: 0, then closed
        #|broken chunk framing: HTTP/1.1 200 OK, then HTTP/1.1 400 Bad Request | Connection: close | Content-Length: 0, then closed
        #|a transfer coding other than chunked: HTTP/1.1 200 OK, then HTTP/1.1 501 Not Implemented | Connection: close | Content-Length: 0, then closed
        #|HTTP/2.0: HTTP/1.1 200 OK, then HTTP/1.1 505 HTTP Version Not Supported | Connection: close | Content-Length: 0, then closed
        #|whitespace before a colon: HTTP/1.1 200 OK, then HTTP/1.1 400 Bad Request | Connection: close | Content-Length: 0, then closed
        #|obsolete line folding: HTTP/1.1 200 OK, then HTTP/1.1 400 Bad Request | Connection: close | Content-Length: 0, then closed
        #|an invalid character in a field name: HTTP/1.1 200 OK, then HTTP/1.1 400 Bad Request | Connection: close | Content-Length: 0, then closed
        #|bare LF line ends: HTTP/1.1 200 OK, then HTTP/1.1 400 Bad Request | Connection: close | Content-Length: 0, then closed
        #|a TLS handshake: HTTP/1.1 200 OK, then HTTP/1.1 400 Bad Request | Connection: close | Content-Length: 0, then closed
      ),
    )
  })
  // Rejected requests are not logged: R1 writes no per-request log lines.
  inspect(
    entries(stopped.logs),
    content=(
      #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
      #|{"level":"info","msg":"listening","listener":"plain","address":"0.0.0.0:*"}
      #|{"level":"info","msg":"listening","listener":"tls","address":"0.0.0.0:*","cert_file":"*/rsa-chain.pem","key_file":"*/rsa-key.pem"}
      #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
    ),
  )
}

///|
/// Reads `n` responses and joins them, separated by `---` lines.
async fn read_responses(conn : Conn, n : Int) -> String {
  let responses = []
  for _ in 0..<n {
    responses.push(read_response(conn))
  }
  responses.join("\n---\n")
}

///|
async test "pipelining: requests sent in one write are all answered, in order, on the same connection" {
  let _ = on_both_ports((smock, over) => {
    let conn = smock.connect(over~)
    defer conn.close()
    conn.write(pipelined)
    assert_eq(read_responses(conn, 5), pipelined_responses)
    // The connection is still open for the next request.
    conn.write("GET /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n")
    inspect(
      read_response(conn),
      content=(
        #|HTTP/1.1 200 OK
        #|Content-Type: application/json
        #|X-Source: smock
        #|Smock-Mock: users; via=default
        #|Content-Length: 23
        #|
        #|{"id":1,"name":"Alice"}
      ),
    )
  })
}

///|
async test "split reads: requests sent in pieces, with pauses between writes, get the same answers" {
  let _ = on_both_ports((smock, over) => {
    let bytes = @utf8.encode(pipelined)
    // Pieces of 7 bytes cut the stream inside request lines, header
    // fields, CRLFs, chunk sizes and chunk data.
    let conn = smock.connect(over~)
    defer conn.close()
    for offset = 0; offset < bytes.length(); offset = offset + 7 {
      let end = if offset + 7 < bytes.length() {
        offset + 7
      } else {
        bytes.length()
      }
      conn.write(bytes[offset:end])
      @async.sleep(2)
    }
    assert_eq(read_responses(conn, 5), pipelined_responses)
    // One byte at a time.
    let chunked = @utf8.encode(
      "POST /users/1 HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n2;a=b\r\nhi\r\n0\r\n\r\nGET /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n",
    )
    for i in 0..<chunked.length() {
      conn.write(chunked[i:i + 1])
      @async.sleep(1)
    }
    inspect(
      read_responses(conn, 2),
      content=(
        #|HTTP/1.1 404 Not Found
        #|Content-Type: application/json
        #|Smock-Mock: users; via=default
        #|Content-Length: 27
        #|
        #|{"error":"no Stub matched"}
        #|---
        #|HTTP/1.1 200 OK
        #|Content-Type: application/json
        #|X-Source: smock
        #|Smock-Mock: users; via=default
        #|Content-Length: 23
        #|
        #|{"id":1,"name":"Alice"}
      ),
    )
  })
}
