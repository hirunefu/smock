// Seam 2 tests of header compression over HTTP/2, over h2c on the plain
// port, sent as raw frames. smock's HPACK encoding table stays at 4,096
// octets however large a table the client allows: smock lowers the
// client's SETTINGS_HEADER_TABLE_SIZE to 4,096 before moonhttp sees it.

///|
/// A Mock that answers every Host, with a Stub for `GET /hello` and one for
/// `GET /echo` whose `x-n` header is the query's `n`.
let hello_and_echo : String =
  #|{ "mocks": [{ "name": "files" }],
  #|  "stubs": [
  #|    { "id": "hello", "mock": "files",
  #|      "request": { "method": "GET", "path": "/hello" },
  #|      "response": { "status": 200, "body": "hi" } },
  #|    { "id": "echo", "mock": "files",
  #|      "request": { "method": "GET", "path": "/echo" },
  #|      "response": { "status": 200, "template": true,
  #|        "headers": { "x-n": "${query.n}" }, "body": "ok" } }] }

///|
/// The dynamic table size updates at the start of the header block `block`
/// (RFC 7541, section 6.3), the only place section 4.2 allows them, read
/// independently of any HPACK decoder.
fn table_size_updates(block : Bytes) -> Array[Int64] {
  let updates = []
  let mut at = 0
  while at < block.length() && (block[at].to_int() & 0xE0) == 0x20 {
    // A prefix integer of five bits (RFC 7541, section 5.1).
    let mut value = (block[at].to_int() & 0x1F).to_int64()
    at += 1
    if value == 31 {
      let mut shift = 0
      for ;; {
        let octet = block[at].to_int()
        at += 1
        value += (octet & 0x7F).to_int64() << shift
        shift += 7
        if (octet & 0x80) == 0 {
          break
        }
      }
    }
    updates.push(value)
  }
  updates
}

///|
async test "h2c: a SETTINGS_HEADER_TABLE_SIZE over 4,096, read as unsigned, reaches moonhttp as 4,096, so no response block has a table size update past it, while a value up to 4,096 and the frame's other settings pass unchanged" {
  with_definitions([("files.json", hello_and_echo)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      for
        advertised in [
          0L, 4096L, 4097L, 65536L, 2147483647L, 2147483648L, 4294967295L,
        ] {
        let raw = smock.raw_h2(settings=false)
        // An initial window of one octet, which lets one octet of the body
        // through.
        raw.send([
          Settings(
            params=[
              (@http2.settings_header_table_size, advertised.to_int()),
              (@http2.settings_initial_window_size, 1),
            ],
            ack=false,
          ),
          headers_frame(
            1,
            raw.block(request_fields("GET", "/hello", "localhost")),
          ),
          Ping(payload=b"\x00\x00\x00\x00\x00\x00\x00\x01", ack=false),
        ])
        let frames = []
        let mut updates = "none"
        while raw.read_frame() is Some(frame) {
          if frame is Ping(ack=true, ..) {
            break
          }
          if frame is Headers(fragment~, ..) {
            let found = table_size_updates(fragment)
            if found.length() > 0 {
              updates = found.map(update => update.to_string()).join(", ")
            }
          }
          frames.push(raw.render_frame(frame))
        }
        raw.close()
        out.push("SETTINGS_HEADER_TABLE_SIZE=\{advertised}:")
        out.push("  table size updates: \{updates}")
        for frame in frames {
          out.push("  \{frame}")
        }
      }
      inspect(
        out.join("\n"),
        content=(
          #|SETTINGS_HEADER_TABLE_SIZE=0:
          #|  table size updates: 0
          #|  SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|  SETTINGS ACK
          #|  HEADERS 1 END_HEADERS [:status: 200, smock-mock: files; via=default, date: <now>, content-length: 2]
          #|  DATA 1 1 octets
          #|SETTINGS_HEADER_TABLE_SIZE=4096:
          #|  table size updates: none
          #|  SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|  SETTINGS ACK
          #|  HEADERS 1 END_HEADERS [:status: 200, smock-mock: files; via=default, date: <now>, content-length: 2]
          #|  DATA 1 1 octets
          #|SETTINGS_HEADER_TABLE_SIZE=4097:
          #|  table size updates: none
          #|  SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|  SETTINGS ACK
          #|  HEADERS 1 END_HEADERS [:status: 200, smock-mock: files; via=default, date: <now>, content-length: 2]
          #|  DATA 1 1 octets
          #|SETTINGS_HEADER_TABLE_SIZE=65536:
          #|  table size updates: none
          #|  SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|  SETTINGS ACK
          #|  HEADERS 1 END_HEADERS [:status: 200, smock-mock: files; via=default, date: <now>, content-length: 2]
          #|  DATA 1 1 octets
          #|SETTINGS_HEADER_TABLE_SIZE=2147483647:
          #|  table size updates: none
          #|  SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|  SETTINGS ACK
          #|  HEADERS 1 END_HEADERS [:status: 200, smock-mock: files; via=default, date: <now>, content-length: 2]
          #|  DATA 1 1 octets
          #|SETTINGS_HEADER_TABLE_SIZE=2147483648:
          #|  table size updates: none
          #|  SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|  SETTINGS ACK
          #|  HEADERS 1 END_HEADERS [:status: 200, smock-mock: files; via=default, date: <now>, content-length: 2]
          #|  DATA 1 1 octets
          #|SETTINGS_HEADER_TABLE_SIZE=4294967295:
          #|  table size updates: none
          #|  SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|  SETTINGS ACK
          #|  HEADERS 1 END_HEADERS [:status: 200, smock-mock: files; via=default, date: <now>, content-length: 2]
          #|  DATA 1 1 octets
        ),
      )
    })
  })
}
