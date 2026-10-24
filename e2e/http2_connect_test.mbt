// Seam 2 tests of a CONNECT over HTTP/2, over h2c on the plain port: it
// reaches the Mocks when its HEADERS arrive, even when they do not end the
// stream, with `:authority` as its target and its Host, as an HTTP/1.1
// CONNECT's authority form does. smock answers it as any request and opens
// no tunnel: a 2xx ends the stream with no `content-length` and no body,
// and DATA the client sends after the HEADERS is discarded.

///|
/// A Mock for the Host `proxy.example.com`, with a Stub that answers a
/// CONNECT to its port 443 with 200, a header and a body, and the Default
/// Mock, with a Stub for `POST /echo` that echoes the body's length.
let tunnels : String =
  #|{ "mocks": [{ "name": "proxy", "hosts": ["proxy.example.com"] },
  #|            { "name": "fallback", "default": true }],
  #|  "stubs": [
  #|    { "id": "tunnel", "mock": "proxy",
  #|      "request": { "method": "CONNECT",
  #|        "path": { "pattern": "proxy\\.example\\.com:443" } },
  #|      "response": { "status": 200, "headers": { "X-Tunnel": "none" },
  #|        "body": "no tunnel opens" } },
  #|    { "id": "echo", "mock": "fallback",
  #|      "request": { "method": "POST", "path": "/echo" },
  #|      "response": { "status": 200, "template": true,
  #|        "body": "${body.length} octets" } } ] }

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
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=65536]
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
