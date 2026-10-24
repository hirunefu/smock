// Seam 2 tests of a CONNECT over HTTP/2, over h2c on the plain port: it
// reaches the Mocks when its HEADERS arrive, even when they do not end the
// stream, with `:authority` as its target and its Host, as an HTTP/1.1
// CONNECT's authority form does. smock answers it as any request and opens
// no tunnel: a 2xx ends the stream with no `content-length` and no body,
// and DATA the client sends after the HEADERS is discarded.

///|
/// A Mock for the Host `proxy.example.com`, with Stubs that answer a
/// CONNECT to its port 443 with 200, a header and a body, one to its port
/// 8000 with the same after a delay, and one to its port 8080 with 407 and
/// a body; and the Default Mock, with a Stub for `POST /upload`.
let tunnels : String =
  #|{ "mocks": [{ "name": "proxy", "hosts": ["proxy.example.com"] },
  #|            { "name": "fallback", "default": true }],
  #|  "stubs": [
  #|    { "id": "tunnel", "mock": "proxy",
  #|      "request": { "method": "CONNECT",
  #|        "path": { "pattern": "proxy\\.example\\.com:443" } },
  #|      "response": { "status": 200, "headers": { "X-Tunnel": "none" },
  #|        "body": "no tunnel opens" } },
  #|    { "id": "slow-tunnel", "mock": "proxy",
  #|      "request": { "method": "CONNECT",
  #|        "path": { "pattern": "proxy\\.example\\.com:8000" } },
  #|      "response": { "status": 200, "body": "no tunnel opens" },
  #|      "fault": { "delay": { "fixed": 200 } } },
  #|    { "id": "proxy-auth", "mock": "proxy",
  #|      "request": { "method": "CONNECT",
  #|        "path": { "pattern": "proxy\\.example\\.com:8080" } },
  #|      "response": { "status": 407,
  #|        "headers": { "Proxy-Authenticate": "Basic realm=proxy" },
  #|        "body": "proxy authentication required" } },
  #|    { "id": "upload", "mock": "fallback",
  #|      "request": { "method": "POST", "path": "/upload" },
  #|      "response": { "status": 201, "body": "stored" } } ] }

///|
/// The fields of a CONNECT to `authority`: `:method` and `:authority`
/// alone, with no `:scheme` and no `:path` (RFC 9113, section 8.5), then
/// `headers`.
fn connect_fields(
  authority : String,
  headers~ : Array[(String, String)] = [],
) -> Array[(String, String)] {
  [(":method", "CONNECT"), (":authority", authority), ..headers]
}

///|
/// A Journal entry as these tests show it: the method and target of its
/// request, its Host, its Mock and Stub, its status, and how many octets of
/// body its request had.
fn connect_entry(entry : Json) -> String {
  guard entry
    is Object(
      {
        "host": host,
        "mock": mock,
        "stub": stub,
        "status": status,
        "request": Object(
          {
            "method": String(meth),
            "target": target,
            "version": String(version),
            "body": Object({ "size": size, .. }),
            ..
          }
        ),
        ..
      }
    ) else {
    return entry.stringify()
  }
  "\{version} \{meth} \{target.stringify()} host=\{host.stringify()} mock=\{mock.stringify()} stub=\{stub.stringify()} status=\{status.stringify()} body=\{size.stringify()} octets"
}

///|
/// The Journal's entries as `connect_entry` shows them, one per line.
async fn connect_journal(smock : Smock) -> String {
  let (_, journal) = smock.journal()
  guard journal is Object({ "entries": Array(entries), .. }) else {
    fail("no entries: \{journal.stringify()}")
  }
  entries.map(connect_entry).join("\n")
}

///|
async test "h2c: a CONNECT reaches its Stub when its HEADERS arrive, even when they do not end the stream, with :authority as its target and Host, and its 2xx ends the stream with no content-length and no DATA, where HTTP/1.1 sends both" {
  with_definitions([("tunnels.json", tunnels)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let out = []
      raw.send([
        headers_frame(
          1,
          raw.block(connect_fields("proxy.example.com:443")),
          end_stream=false,
        ),
      ])
      out.push("HEADERS that do not end the stream:")
      out.push(raw.frames_until_stream_ends(1))
      // moonhttp resets the third with PROTOCOL_ERROR, since its
      // `content-length` is not what the stream carried, in the frame that
      // brings it: it never reaches the Mocks.
      raw.send([
        headers_frame(3, raw.block(connect_fields("proxy.example.com:443"))),
        headers_frame(
          5,
          raw.block(
            connect_fields("proxy.example.com:443", headers=[
              ("content-length", "5"),
            ]),
          ),
        ),
        Ping(payload=b"\x00\x00\x00\x00\x00\x00\x00\x01", ack=false),
      ])
      out.push(
        "HEADERS that end the stream, then HEADERS that end it with content-length: 5:",
      )
      out.push(raw.frames_until_ping_ack())
      out.push("HTTP/1.1:")
      out.push(
        smock.request("CONNECT", "proxy.example.com:443", headers=[
          ("Host", "proxy.example.com:443"),
        ]),
      )
      out.push("Journal:")
      out.push(connect_journal(smock))
      inspect(
        out.join("\n"),
        content=(
          #|HEADERS that do not end the stream:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_STREAM END_HEADERS [:status: 200, x-tunnel: none, date: <now>]
          #|HEADERS that end the stream, then HEADERS that end it with content-length: 5:
          #|HEADERS 3 END_STREAM END_HEADERS [:status: 200, x-tunnel: none, date: <now>]
          #|RST_STREAM 5 PROTOCOL_ERROR
          #|HTTP/1.1:
          #|HTTP/1.1 200 OK
          #|X-Tunnel: none
          #|Date: <now>
          #|Content-Length: 15
          #|
          #|no tunnel opens
          #|Journal:
          #|HTTP/2 CONNECT "proxy.example.com:443" host="proxy.example.com" mock="proxy" stub="tunnel" status=200 body=0 octets
          #|HTTP/2 CONNECT "proxy.example.com:443" host="proxy.example.com" mock="proxy" stub="tunnel" status=200 body=0 octets
          #|HTTP/1.1 CONNECT "proxy.example.com:443" host="proxy.example.com" mock="proxy" stub="tunnel" status=200 body=0 octets
        ),
      )
    })
  })
}

///|
async test "h2c: a CONNECT's 2xx after a delay also ends the stream with no content-length and no DATA, and a status other than 2xx is framed as any response's, with its length and body" {
  with_definitions([("tunnels.json", tunnels)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      raw.send([
        headers_frame(
          1,
          raw.block(connect_fields("proxy.example.com:8000")),
          end_stream=false,
        ),
        headers_frame(
          3,
          raw.block(connect_fields("proxy.example.com:8080")),
          end_stream=false,
        ),
      ])
      inspect(
        raw.frames_until_stream_ends(1),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 3 END_HEADERS [:status: 407, proxy-authenticate: Basic realm=proxy, date: <now>, content-length: 29]
          #|DATA 3 END_STREAM 29 octets
          #|HEADERS 1 END_STREAM END_HEADERS [:status: 200, date: <now>]
        ),
      )
    })
  })
}

///|
async test "h2c: DATA sent on a CONNECT's stream after its HEADERS is discarded and acknowledged, so the connection's window reopens, and a request on another stream is answered after it" {
  with_definitions([("tunnels.json", tunnels)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let out = []
      raw.send([
        headers_frame(
          1,
          raw.block(connect_fields("proxy.example.com:443")),
          end_stream=false,
        ),
      ])
      out.push("The CONNECT:")
      out.push(raw.frames_until_stream_ends(1))
      // The whole of the connection's window, in frames of the largest size
      // smock allows.
      let frames : Array[@http2.Frame] = []
      let mut left = 65535
      while left > 0 {
        let size = if left < 16384 { left } else { 16384 }
        frames.push(
          Data(
            stream_id=1,
            data=Bytes::make(size, b'x'),
            end_stream=false,
            padding=0,
          ),
        )
        left -= size
      }
      frames.push(Ping(payload=b"\x00\x00\x00\x00\x00\x00\x00\x01", ack=false))
      raw.send(frames)
      out.push("65,535 octets of DATA on its stream:")
      out.push(raw.frames_until_ping_ack())
      // Past the connection's window, unless smock has reopened it.
      raw.send([
        headers_frame(
          3,
          raw.block(request_fields("POST", "/upload", "localhost")),
          end_stream=false,
        ),
        Data(stream_id=3, data=b"abcdef", end_stream=true, padding=0),
      ])
      out.push("A request with a body on another stream:")
      out.push(raw.frames_until_stream_ends(3))
      raw.send([
        Data(stream_id=1, data=b"", end_stream=true, padding=0),
        Ping(payload=b"\x00\x00\x00\x00\x00\x00\x00\x02", ack=false),
      ])
      out.push("The end of the CONNECT's stream:")
      out.push(raw.frames_until_ping_ack())
      out.push("Journal:")
      out.push(connect_journal(smock))
      inspect(
        out.join("\n"),
        content=(
          #|The CONNECT:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_STREAM END_HEADERS [:status: 200, x-tunnel: none, date: <now>]
          #|65,535 octets of DATA on its stream:
          #|WINDOW_UPDATE 0 +32768
          #|WINDOW_UPDATE 1 +32768
          #|WINDOW_UPDATE 0 +32767
          #|WINDOW_UPDATE 1 +32767
          #|A request with a body on another stream:
          #|HEADERS 3 END_HEADERS [:status: 201, smock-mock: fallback; via=default, date: <now>, content-length: 6]
          #|DATA 3 END_STREAM 6 octets
          #|The end of the CONNECT's stream:
          #|
          #|Journal:
          #|HTTP/2 CONNECT "proxy.example.com:443" host="proxy.example.com" mock="proxy" stub="tunnel" status=200 body=0 octets
          #|HTTP/2 POST "/upload" host="localhost" mock="fallback" stub="upload" status=201 body=6 octets
        ),
      )
    })
  })
}

///|
/// Opens a stream with a CONNECT to `authority`, which moonhttp's client
/// sends with no `:scheme` and no `:path`, and leaves it open. Returns the
/// stream's ID.
async fn H2Client::connect(self : H2Client, authority : String) -> Int32 {
  let stream = self.conn.next_stream()
  self.conn.headers(stream, [
    @header.Header::of(":method", "CONNECT"),
    @header.Header::of(":authority", authority),
  ])
  self.flush()
  stream
}

///|
async test "h2c: an unmatched CONNECT gets the unmatched response, body included, that HTTP/1.1 gives it, from the Mock its Host chooses or the Default Mock" {
  with_definitions([("tunnels.json", tunnels)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let out = []
      for authority in ["proxy.example.com:8443", "elsewhere.example.com:443"] {
        out.push(client.response(client.connect(authority)).render())
        out.push(
          smock.request("CONNECT", authority, headers=[("Host", authority)]),
        )
      }
      inspect(
        out.join("\n---\n"),
        content=(
          #|404
          #|content-type: application/json
          #|smock-near-miss: tunnel; failed=path
          #|date: <now>
          #|content-length: 27
          #|
          #|{"error":"no Stub matched"}
          #|---
          #|HTTP/1.1 404 Not Found
          #|Content-Type: application/json
          #|Smock-Near-Miss: tunnel; failed=path
          #|Date: <now>
          #|Content-Length: 27
          #|
          #|{"error":"no Stub matched"}
          #|---
          #|404
          #|content-type: application/json
          #|smock-near-miss: upload; failed=method,path
          #|smock-mock: fallback; via=default
          #|date: <now>
          #|content-length: 27
          #|
          #|{"error":"no Stub matched"}
          #|---
          #|HTTP/1.1 404 Not Found
          #|Content-Type: application/json
          #|Smock-Near-Miss: upload; failed=method,path
          #|Smock-Mock: fallback; via=default
          #|Date: <now>
          #|Content-Length: 27
          #|
          #|{"error":"no Stub matched"}
        ),
      )
    })
  })
}

///|
async test "h2c: a CONNECT whose :authority is not a host and a port, the authority-form HTTP/1.1 holds a CONNECT's target to, gets 400, followed by RST_STREAM PROTOCOL_ERROR when its HEADERS did not end the stream" {
  with_definitions([("tunnels.json", tunnels)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      raw.send([Ping(payload=b"\x00\x00\x00\x00\x00\x00\x00\x01", ack=false)])
      let out = [raw.frames_until_ping_ack()]
      let mut stream = 1
      for
        connect in [
          ("proxy example.com:443", false),
          ("proxy.example.com", false),
          ("proxy.example.com:https", false),
          ("[::1", false),
          ("", false),
          ("proxy.example.com", true),
          ("proxy.example.com:443", false),
        ] {
        let (authority, end_stream) = connect
        raw.send([
          headers_frame(
            stream,
            raw.block(connect_fields(authority)),
            end_stream~,
          ),
          Ping(payload=b"\x00\x00\x00\x00\x00\x00\x00\x01", ack=false),
        ])
        let ends = if end_stream { "end" } else { "do not end" }
        out.push(
          "\{authority.escape()}, HEADERS that \{ends} the stream: \{raw.frames_until_ping_ack().replace_all(old="\n", new=" | ")}",
        )
        stream += 2
      }
      out.push("HTTP/1.1, a target that is not a host and a port:")
      out.push(
        smock.request("CONNECT", "proxy.example.com", headers=[
          ("Host", "proxy.example.com"),
        ]),
      )
      out.push("Journal:")
      out.push(connect_journal(smock))
      inspect(
        out.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|"proxy example.com:443", HEADERS that do not end the stream: HEADERS 1 END_STREAM END_HEADERS [:status: 400, date: <now>, content-length: 0] | RST_STREAM 1 PROTOCOL_ERROR
          #|"proxy.example.com", HEADERS that do not end the stream: HEADERS 3 END_STREAM END_HEADERS [:status: 400, date: <now>, content-length: 0] | RST_STREAM 3 PROTOCOL_ERROR
          #|"proxy.example.com:https", HEADERS that do not end the stream: HEADERS 5 END_STREAM END_HEADERS [:status: 400, date: <now>, content-length: 0] | RST_STREAM 5 PROTOCOL_ERROR
          #|"[::1", HEADERS that do not end the stream: HEADERS 7 END_STREAM END_HEADERS [:status: 400, date: <now>, content-length: 0] | RST_STREAM 7 PROTOCOL_ERROR
          #|"", HEADERS that do not end the stream: HEADERS 9 END_STREAM END_HEADERS [:status: 400, date: <now>, content-length: 0] | RST_STREAM 9 PROTOCOL_ERROR
          #|"proxy.example.com", HEADERS that end the stream: HEADERS 11 END_STREAM END_HEADERS [:status: 400, date: <now>, content-length: 0]
          #|"proxy.example.com:443", HEADERS that do not end the stream: HEADERS 13 END_STREAM END_HEADERS [:status: 200, x-tunnel: none, date: <now>]
          #|HTTP/1.1, a target that is not a host and a port:
          #|HTTP/1.1 400 Bad Request
          #|Date: <now>
          #|Connection: close
          #|Content-Length: 0
          #|
          #|
          #|Journal:
          #|HTTP/2 CONNECT "proxy.example.com:443" host="proxy.example.com" mock="proxy" stub="tunnel" status=200 body=0 octets
        ),
      )
    })
  })
}
