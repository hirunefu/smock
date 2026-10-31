// Seam 2 tests of the defence against CONTINUATION floods over h2c, sent as
// raw frames with moonhttp's frame encoder: a header block, its HEADERS and
// CONTINUATION frames, is held to moonhttp's bound as received, twice
// `--header-size-limit`, and must end within the read timeout; empty
// CONTINUATION frames count as frames that do no work. Each test checks what
// the client receives, the log line, and that a fresh connection is served
// right after.

///|
/// A CONTINUATION frame on `stream` with no octets, which ends its header
/// block when `end_headers` is true.
fn empty_continuation(
  stream : Int32,
  end_headers~ : Bool = false,
) -> @http2.Frame {
  Continuation(stream_id=stream, fragment=b"", end_headers~)
}

///|
/// A HEADERS frame on `stream` that begins a header block with `fragment`
/// and does not end it, and ends the stream.
fn opening(stream : Int32, fragment : Bytes) -> @http2.Frame {
  Headers(
    stream_id=stream,
    fragment~,
    end_stream=true,
    end_headers=false,
    priority=None,
    padding=0,
  )
}

///|
async test "h2c: empty CONTINUATION frames that end no header block count as frames that do no work: the 100th after the client's SETTINGS gets GOAWAY ENHANCE_YOUR_CALM and one log line, while an empty one that ends its block does not count; a fresh connection is served" {
  with_definitions([("faults.json", faults)], dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      // A stream answered first, so that the GOAWAY names it.
      out.push(
        smock.flood(
          "a header block, then 100 empty CONTINUATION frames",
          setup=raw => [raw.get(1, "/fast")],
          ready=frame => ends_stream(frame, 1),
          raw => {
            [
              opening(3, raw.block(request_fields("GET", "/fast", "localhost"))),
              ..times(empty_continuation(3), 100),
            ]
          },
        ),
      )
      // The client's SETTINGS and 99 empty CONTINUATION frames make 100;
      // the one that ends the block does not count, so the stream is
      // answered, and one PRIORITY frame then passes the bound.
      out.push(
        smock.flood(
          "a header block, 99 empty CONTINUATION frames and an empty one that ends it",
          setup=raw => {
            [
              opening(1, raw.block(request_fields("GET", "/fast", "localhost"))),
              ..times(empty_continuation(1), 99),
              empty_continuation(1, end_headers=true),
            ]
          },
          ready=frame => ends_stream(frame, 1),
          _ => {
            [
              Priority(stream_id=3, priority={
                exclusive: false,
                stream_dependency: 0,
                weight: 16,
              }),
            ]
          },
        ),
      )
      inspect(
        out.join("\n"),
        content=(
          #|a header block, then 100 empty CONTINUATION frames:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
          #|DATA 1 END_STREAM 4 octets
          #|flood:
          #|GOAWAY last=1 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
          #|a header block, 99 empty CONTINUATION frames and an empty one that ends it:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
          #|DATA 1 END_STREAM 4 octets
          #|flood:
          #|GOAWAY last=1 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
        ),
      )
    })
    inspect(
      defence_entries(stopped.logs),
      content=(
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"empty CONTINUATION"}
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"PRIORITY"}
      ),
    )
  })
}

///|
/// `block`, `piece` octets at a time, in CONTINUATION frames on `stream`,
/// the last of which ends the header block when `ends` is true.
fn continuations(
  stream : Int32,
  block : Bytes,
  piece : Int32,
  ends~ : Bool,
) -> Array[@http2.Frame] {
  let frames = []
  for at = 0; at < block.length(); at = at + piece {
    let end = if at + piece < block.length() {
      at + piece
    } else {
      block.length()
    }
    frames.push(
      @http2.Frame::Continuation(
        stream_id=stream,
        fragment=block[at:end].to_owned(),
        end_headers=ends && end == block.length(),
      ),
    )
  }
  frames
}

///|
/// The HPACK integer `n` with a 7-bit prefix and no Huffman flag, as the
/// length of a string literal (RFC 7541, section 5.1).
fn hpack_length(n : Int32) -> Bytes {
  let out = @buffer.Buffer()
  if n < 127 {
    out.write_byte(n.to_byte())
    return out.to_bytes()
  }
  out.write_byte(b'\x7f')
  let mut rest = n - 127
  while rest >= 128 {
    out.write_byte((rest % 128 + 128).to_byte())
    rest = rest / 128
  }
  out.write_byte(rest.to_byte())
  out.to_bytes()
}

///|
/// A header block of exactly `size` octets, for `GET /` to `localhost`
/// with an `x-pad` field of `a`s, that leaves both HPACK tables as they
/// are: entries of the static table, and literals without indexing, none
/// Huffman-coded.
fn exact_block(size : Int32) -> Bytes {
  let out = @buffer.Buffer()
  // `:method: GET`, `:scheme: http` and `:path: /`, then `:authority`, the
  // name of static entry 1, then `x-pad`, a new name.
  out.write_bytes(b"\x82\x86\x84\x01\x09localhost\x00\x05x-pad")
  let named = out.length()
  for octets = 1; ; octets = octets + 1 {
    let n = size - named - octets
    let length = hpack_length(n)
    if length.length() == octets {
      out.write_bytes(length)
      out.write_bytes(Bytes::make(n, b'a'))
      return out.to_bytes()
    }
  }
}

///|
async test "h2c: a header block that passes moonhttp's bound as received, twice --header-size-limit, with large CONTINUATION frames gets GOAWAY ENHANCE_YOUR_CALM and one log line naming a CONTINUATION flood, while a block at the bound is taken, padding and priority aside; a fresh connection is served" {
  with_definitions([("faults.json", faults)], dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      inspect(
        smock.flood(
          "a block of 32768 octets on stream 1, in a padded HEADERS frame with a priority and 7 CONTINUATION frames, then a GET on stream 3",
          setup=raw => {
            let block = exact_block(32768)
            [
              Headers(
                stream_id=1,
                fragment=block[:4096].to_owned(),
                end_stream=true,
                end_headers=false,
                priority=Some({
                  exclusive: false,
                  stream_dependency: 0,
                  weight: 16,
                }),
                padding=16,
              ),
              ..continuations(1, block[4096:].to_owned(), 4096, ends=true),
              raw.get(3, "/fast"),
            ]
          },
          ready=frame => ends_stream(frame, 3),
          _ => {
            // 32769 octets: the last CONTINUATION frame passes the bound by
            // one.
            [
              opening(5, b"\x82"),
              ..continuations(
                5,
                Bytes::make(8 * 4096, b'\x00'),
                4096,
                ends=false,
              ),
            ]
          },
        ),
        content=(
          #|a block of 32768 octets on stream 1, in a padded HEADERS frame with a priority and 7 CONTINUATION frames, then a GET on stream 3:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|RST_STREAM 1 ENHANCE_YOUR_CALM
          #|HEADERS 3 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
          #|DATA 3 END_STREAM 4 octets
          #|flood:
          #|GOAWAY last=3 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
        ),
      )
    })
    inspect(
      defence_entries(stopped.logs),
      content=(
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"CONTINUATION flood","frame":"CONTINUATION"}
      ),
    )
  })
}
