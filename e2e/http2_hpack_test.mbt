// Seam 2 tests of header compression over HTTP/2, over h2c on the plain
// port, sent as raw frames: the HPACK bomb row of the defences.
//
// - smock's HPACK encoding table stays at 4,096 octets however large a
//   table the client allows: smock lowers the client's
//   SETTINGS_HEADER_TABLE_SIZE to 4,096 before moonhttp sees it.
// - A block that names a large table entry over and over is held to the
//   header limits (431), and past moonhttp's bound, twice
//   `--header-size-limit`, to RST_STREAM ENHANCE_YOUR_CALM. Past 2^31
//   decoded octets, where moonhttp 0.14.0's count wraps, smock's own check
//   still gives 431.
// - A block that does not decode, or that asks for a decoding table larger
//   than 4,096 octets, ends the connection with GOAWAY COMPRESSION_ERROR.

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

///|
async test "h2c: with a header table of 2^31-1 allowed, a few thousand responses with distinct templated header values all decode with an HPACK decoder held to 4,096 octets, and none has a table size update past it" {
  with_definitions([("files.json", hello_and_echo)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2(settings=false)
      defer raw.close()
      raw.send([
        Settings(
          params=[(@http2.settings_header_table_size, 0x7FFF_FFFF)],
          ack=false,
        ),
      ])
      // RawH2's decoder is held to 4,096 octets: a table size update past
      // it does not decode.
      let batches = 30
      let batch = 100
      let mut blocks = 0
      let mut decoded = 0
      let mut matched = 0
      let mut data = 0
      let mut ended = 0
      let failures = []
      let updates = []
      let mut stream = 1
      for _ in 0..<batches {
        let frames = []
        let first = stream
        for _ in 0..<batch {
          frames.push(
            headers_frame(
              stream,
              raw.block(request_fields("GET", "/echo?n=\{stream}", "localhost")),
            ),
          )
          stream += 2
        }
        raw.send(frames)
        let mut open = batch
        while open > 0 {
          guard raw.read_frame() is Some(frame) else {
            fail("smock closed the connection")
          }
          match frame {
            Headers(stream_id~, fragment~, end_stream~, ..) => {
              blocks += 1
              for update in table_size_updates(fragment) {
                updates.push(update)
              }
              let fields = raw.fields(fragment) catch {
                err => {
                  failures.push("stream \{stream_id}: \{err}")
                  []
                }
              }
              if fields.length() > 0 {
                decoded += 1
              }
              if fields.contains(("x-n", stream_id.to_string())) {
                matched += 1
              }
              if end_stream {
                open -= 1
                ended += 1
              }
            }
            Data(stream_id~, end_stream~, ..) => {
              guard stream_id >= first && stream_id < stream else {
                fail("DATA on stream \{stream_id}")
              }
              data += 1
              if end_stream {
                open -= 1
                ended += 1
              }
            }
            Settings(..) => ()
            other => fail("an unexpected frame: \{raw.render_frame(other)}")
          }
        }
      }
      let shown_updates = if updates.is_empty() {
        "none"
      } else {
        updates.map(update => update.to_string()).join(", ")
      }
      let shown = if failures.length() > 3 {
        [..failures[:3], "..."]
      } else {
        failures
      }
      inspect(
        (
          $|Requests: \{batches * batch}, streams ended: \{ended}, DATA frames: \{data}
          $|Response blocks: \{blocks}, decoded: \{decoded}, with the stream's own x-n: \{matched}
          $|Table size updates: \{shown_updates}
          $|Blocks that do not decode: \{failures.length()}
          $|\{shown.join("\n")}
        ),
        content=(
          #|Requests: 3000, streams ended: 3000, DATA frames: 3000
          #|Response blocks: 3000, decoded: 3000, with the stream's own x-n: 3000
          #|Table size updates: none
          #|Blocks that do not decode: 0
          #|
        ),
      )
    })
  })
}

///|
async test "h2c: an HPACK bomb, a block that names a large table entry over and over, gets 431 while its decoded list is within twice --header-size-limit, else RST_STREAM ENHANCE_YOUR_CALM with no status, too many fields named over and over get 431, and the connection goes on" {
  with_definitions([("files.json", hello_and_echo)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let hello = request_fields("GET", "/hello", "localhost")
      // An entry of 3,938 octets, which fits the table of 4,096 octets with
      // those of `:path` and `:authority`, so that none is evicted.
      let bomb = ("x-bomb", String::make(3900, 'b'))
      let small = ("x-a", "1")
      let out = []
      // Each stream's block, made in the order they are sent, as the
      // client's and smock's tables must stay in step: after the first, each
      // field is an index of one octet.
      let streams = [
        ("the entry once", [..hello, bomb]),
        ("the entry 5 times", [..hello, ..Array::make(5, bomb)]),
        ("the entry 16,000 times", [..hello, ..Array::make(16000, bomb)]),
        ("a small field 100 times", [..hello, ..Array::make(100, small)]),
        ("a small field 101 times", [..hello, ..Array::make(101, small)]),
        ("no more", hello),
      ]
      let frames = []
      for i, case in streams {
        let (label, fields) = case
        let block = raw.block(fields)
        out.push(
          "Stream \{2 * i + 1}, \{label}: a block of \{block.length()} octets, a list of \{list_size(fields)}",
        )
        frames.push(headers_frame(2 * i + 1, block))
      }
      raw.send(frames)
      out.push(raw.frames_until_stream_ends(2 * streams.length() - 1))
      let client = smock.h2c()
      defer client.close()
      let response = client.request("GET", "/hello", authority="localhost")
      out.push("A fresh connection: \{response.line()}")
      out.push("Journal:")
      out.push(journaled(smock))
      out.push(smock.metric("smock_requests_total"))
      inspect(
        out.join("\n"),
        content=(
          #|Stream 1, the entry once: a block of 2952 octets, a list of 4117
          #|Stream 3, the entry 5 times: a block of 9 octets, a list of 19869
          #|Stream 5, the entry 16,000 times: a block of 16004 octets, a list of 63008179
          #|Stream 7, a small field 100 times: a block of 110 octets, a list of 3779
          #|Stream 9, a small field 101 times: a block of 105 octets, a list of 3815
          #|Stream 11, no more: a block of 4 octets, a list of 179
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, smock-mock: files; via=default, date: <now>, content-length: 2]
          #|DATA 1 END_STREAM 2 octets
          #|HEADERS 3 END_STREAM END_HEADERS [:status: 431, date: <now>, content-length: 0]
          #|RST_STREAM 5 ENHANCE_YOUR_CALM
          #|HEADERS 7 END_HEADERS [:status: 200, smock-mock: files; via=default, date: <now>, content-length: 2]
          #|DATA 7 END_STREAM 2 octets
          #|HEADERS 9 END_STREAM END_HEADERS [:status: 431, date: <now>, content-length: 0]
          #|HEADERS 11 END_HEADERS [:status: 200, smock-mock: files; via=default, date: <now>, content-length: 2]
          #|DATA 11 END_STREAM 2 octets
          #|A fresh connection: 200 [smock-mock: files; via=default, date: <now>, content-length: 2] 2 octets, end
          #|Journal:
          #|GET /hello
          #|GET /hello
          #|GET /hello
          #|GET /hello
          #|smock_requests_total{mock="files",stub="hello"} 4
          #|smock_requests_total{mock="",stub=""} 2
        ),
      )
    })
  })
}

///|
/// HEADERS on `stream` that end it, with the header block `block` split
/// into frames of at most 16,384 octets, the frame size smock advertises:
/// the HEADERS frame, then CONTINUATION frames, the last of which ends the
/// block.
fn hpack_block_frames(stream : Int32, block : Bytes) -> Array[@http2.Frame] {
  let frames = []
  let mut at = 0
  while at < block.length() {
    let end = if block.length() - at > 16384 {
      at + 16384
    } else {
      block.length()
    }
    let fragment = block[at:end].to_owned()
    let end_headers = end == block.length()
    frames.push(
      if at == 0 {
        @http2.Frame::Headers(
          stream_id=stream,
          fragment~,
          end_stream=true,
          end_headers~,
          priority=None,
          padding=0,
        )
      } else {
        Continuation(stream_id=stream, fragment~, end_headers~)
      },
    )
    at = end
  }
  frames
}

///|
async test "h2c: an HPACK bomb that decodes to more than 2^31 octets, under a --header-size-limit large enough to let its block through, still gets 431 from smock's own check, although moonhttp 0.14.0's count of the list wraps past its bound" {
  with_definitions([("files.json", hello_and_echo)], dir => {
    let args = ["--dir", dir, "--port", "0", "--header-size-limit", "300000"]
    let _ = with_smock(args, smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let hello = request_fields("GET", "/hello", "localhost")
      let bomb = ("x-bomb", String::make(3900, 'b'))
      raw.send([headers_frame(1, raw.block([..hello, bomb]))])
      let out = []
      // The entry is the newest in the table, index 62 (0xBE as an indexed
      // field), and each copy counts 3,938 octets. 560,000 copies count
      // 2,205,280,000, past 2^31-1: moonhttp counts the list in 32 bits, so
      // its count wraps negative, and it keeps the fields after the wrap and
      // raises nothing. smock's own count stops at the first field past
      // --header-size-limit. A moonhttp that counts in 64 bits resets
      // stream 5 as it resets stream 3.
      for i, copies in [500000, 560000] {
        let stream = 2 * i + 3
        let block = raw.block(hello) + Bytes::make(copies, b'\xbe')
        raw.send(hpack_block_frames(stream, block))
        let size = list_size(hello).to_int64() + copies.to_int64() * 3938L
        out.push(
          "Stream \{stream}: a block of \{block.length()} octets, under the bound of 600,000, a list of \{size}",
        )
        out.push(raw.frames_until_stream_ends(stream))
      }
      let client = smock.h2c()
      defer client.close()
      let response = client.request("GET", "/hello", authority="localhost")
      out.push("A fresh connection: \{response.line()}")
      inspect(
        out.join("\n"),
        content=(
          #|Stream 3: a block of 500004 octets, under the bound of 600,000, a list of 1969000179
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=600000]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, smock-mock: files; via=default, date: <now>, content-length: 2]
          #|DATA 1 END_STREAM 2 octets
          #|RST_STREAM 3 ENHANCE_YOUR_CALM
          #|Stream 5: a block of 560004 octets, under the bound of 600,000, a list of 2205280179
          #|HEADERS 5 END_STREAM END_HEADERS [:status: 431, date: <now>, content-length: 0]
          #|A fresh connection: 200 [smock-mock: files; via=default, date: <now>, content-length: 2] 2 octets, end
        ),
      )
    })
  })
}

///|
/// The header block of `GET /hello` to `localhost` with no field added to
/// the dynamic table: indexes of the static table and literals without
/// indexing (RFC 7541, sections 6.1 and 6.2.2), so that octets after it
/// meet the table the blocks before left.
let hello_unindexed : Bytes = b"\x82\x86\x04\x06/hello\x01\x09localhost"

///|
async test "h2c: a header block that does not decode, with a Huffman code with EOS or bad padding, an index that names no entry, or a table size update past 4,096 octets, the size of smock's decoding table, gets GOAWAY COMPRESSION_ERROR, and a fresh connection is served; the table keeps an entry of 4,096 octets and not one larger" {
  with_definitions([("files.json", hello_and_echo)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      // Each case: the fields stream 1 adds to `GET /hello`, then the block
      // of stream 3.
      for
        case in [
          (
            "a Huffman code with EOS",
            [],
            hello_unindexed + b"\x00\x03x-a\x84\xff\xff\xff\xff",
          ),
          (
            "a Huffman code padded with more than seven bits",
            [],
            hello_unindexed + b"\x00\x03x-a\x82\x1f\xff",
          ),
          (
            "a Huffman code padded with zeros",
            [],
            hello_unindexed + b"\x00\x03x-a\x81\x18",
          ),
          ("index 0", [], hello_unindexed + b"\x80"),
          ("an index past the table", [], hello_unindexed + b"\xe4"),
          (
            "a table size update to 4,097",
            [],
            @hpack.size_update(4097) + hello_unindexed,
          ),
          (
            "a table size update to 4,096",
            [],
            @hpack.size_update(4096) + hello_unindexed,
          ),
          (
            "an index to an entry of 4,097 octets, which the table does not keep",
            [("x-big", String::make(4060, 'b'))],
            hello_unindexed + b"\xbe",
          ),
          (
            "an index to an entry of 4,096 octets, which the table keeps",
            [("x-big", String::make(4059, 'b'))],
            hello_unindexed + b"\xbe",
          ),
        ] {
        let (label, added, block) = case
        let raw = smock.raw_h2()
        let hello = request_fields("GET", "/hello", "localhost")
        raw.send([
          headers_frame(1, raw.block([..hello, ..added])),
          headers_frame(3, block),
        ])
        out.push("\{label}:")
        // The frames until stream 3 ends or smock closes the connection,
        // with the GOAWAY's debug data, which says why.
        for ;; {
          guard raw.read_frame() is Some(frame) else {
            out.push("  closed")
            break
          }
          match frame {
            Settings(..) => continue
            GoAway(debug~, ..) =>
              out.push(
                "  \{raw.render_frame(frame)}: \{@utf8.decode_lossy(debug)}",
              )
            _ => out.push("  \{raw.render_frame(frame)}")
          }
          if frame is Data(stream_id=3, end_stream=true, ..) {
            break
          }
        }
        raw.close()
        let client = smock.h2c()
        let response = client.request("GET", "/hello", authority="localhost")
        client.close()
        out.push("  a fresh connection: \{response.status}")
      }
      inspect(
        out.join("\n"),
        content=(
          #|a Huffman code with EOS:
          #|  HEADERS 1 END_HEADERS [:status: 200, smock-mock: files; via=default, date: <now>, content-length: 2]
          #|  DATA 1 END_STREAM 2 octets
          #|  GOAWAY last=1 COMPRESSION_ERROR: Malformed(a Huffman string literal: Eos)
          #|  closed
          #|  a fresh connection: 200
          #|a Huffman code padded with more than seven bits:
          #|  HEADERS 1 END_HEADERS [:status: 200, smock-mock: files; via=default, date: <now>, content-length: 2]
          #|  DATA 1 END_STREAM 2 octets
          #|  GOAWAY last=1 COMPRESSION_ERROR: Malformed(a Huffman string literal: Padding(more than seven bits))
          #|  closed
          #|  a fresh connection: 200
          #|a Huffman code padded with zeros:
          #|  HEADERS 1 END_HEADERS [:status: 200, smock-mock: files; via=default, date: <now>, content-length: 2]
          #|  DATA 1 END_STREAM 2 octets
          #|  GOAWAY last=1 COMPRESSION_ERROR: Malformed(a Huffman string literal: Padding(not a run of ones))
          #|  closed
          #|  a fresh connection: 200
          #|index 0:
          #|  HEADERS 1 END_HEADERS [:status: 200, smock-mock: files; via=default, date: <now>, content-length: 2]
          #|  DATA 1 END_STREAM 2 octets
          #|  GOAWAY last=1 COMPRESSION_ERROR: Malformed(indexed header field with index 0)
          #|  closed
          #|  a fresh connection: 200
          #|an index past the table:
          #|  HEADERS 1 END_HEADERS [:status: 200, smock-mock: files; via=default, date: <now>, content-length: 2]
          #|  DATA 1 END_STREAM 2 octets
          #|  GOAWAY last=1 COMPRESSION_ERROR: Index(got=100)
          #|  closed
          #|  a fresh connection: 200
          #|a table size update to 4,097:
          #|  HEADERS 1 END_HEADERS [:status: 200, smock-mock: files; via=default, date: <now>, content-length: 2]
          #|  DATA 1 END_STREAM 2 octets
          #|  GOAWAY last=1 COMPRESSION_ERROR: Malformed(a dynamic table size update to 4097, past the agreed 4096)
          #|  closed
          #|  a fresh connection: 200
          #|a table size update to 4,096:
          #|  HEADERS 1 END_HEADERS [:status: 200, smock-mock: files; via=default, date: <now>, content-length: 2]
          #|  DATA 1 END_STREAM 2 octets
          #|  HEADERS 3 END_HEADERS [:status: 200, smock-mock: files; via=default, date: <now>, content-length: 2]
          #|  DATA 3 END_STREAM 2 octets
          #|  a fresh connection: 200
          #|an index to an entry of 4,097 octets, which the table does not keep:
          #|  HEADERS 1 END_HEADERS [:status: 200, smock-mock: files; via=default, date: <now>, content-length: 2]
          #|  DATA 1 END_STREAM 2 octets
          #|  GOAWAY last=1 COMPRESSION_ERROR: Index(got=62)
          #|  closed
          #|  a fresh connection: 200
          #|an index to an entry of 4,096 octets, which the table keeps:
          #|  HEADERS 1 END_HEADERS [:status: 200, smock-mock: files; via=default, date: <now>, content-length: 2]
          #|  DATA 1 END_STREAM 2 octets
          #|  HEADERS 3 END_HEADERS [:status: 200, smock-mock: files; via=default, date: <now>, content-length: 2]
          #|  DATA 3 END_STREAM 2 octets
          #|  a fresh connection: 200
        ),
      )
    })
  })
}
