// Seam 2 tests of the header limits over HTTP/2, over h2c on the plain port:
// a header list over `--header-size-limit`, counted as RFC 7541 counts it,
// or with more than `--header-count-limit` regular fields, gets 431 on its
// stream, as on HTTP/1.1. moonhttp is given twice the size limit as its own
// bound, which smock advertises: a decoded list past it is reset with
// ENHANCE_YOUR_CALM, and a header block past it as received ends the
// connection.

///|
async test "h2c: smock advertises twice --header-size-limit as SETTINGS_MAX_HEADER_LIST_SIZE, 32768 with the default, from SMOCK_HEADER_SIZE_LIMIT too, and at most 2^31-1" {
  with_definitions([("files.json", uploads)], dir => {
    let out = []
    for
      run in [
        ("default", [], Map([])),
        ("--header-size-limit 1000", ["--header-size-limit", "1000"], Map([])),
        (
          "SMOCK_HEADER_SIZE_LIMIT=1000",
          [],
          { "SMOCK_HEADER_SIZE_LIMIT": "1000" },
        ),
        (
          "--header-size-limit 1073741823",
          ["--header-size-limit", "1073741823"],
          Map([]),
        ),
        (
          "--header-size-limit 1073741824, the largest",
          ["--header-size-limit", "1073741824"],
          Map([]),
        ),
      ] {
      let (label, flags, env) = run
      let args = ["--dir", dir, "--port", "0", ..flags]
      let _ = with_smock(args, env~, smock => {
        let raw = smock.raw_h2()
        defer raw.close()
        guard raw.read_frame() is Some(frame) else {
          fail("smock sent no SETTINGS")
        }
        out.push("\{label}: \{raw.render_frame(frame)}")
      })
    }
    inspect(
      out.join("\n"),
      content=(
        #|default: SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
        #|--header-size-limit 1000: SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=2000]
        #|SMOCK_HEADER_SIZE_LIMIT=1000: SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=2000]
        #|--header-size-limit 1073741823: SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=2147483646]
        #|--header-size-limit 1073741824, the largest: SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=2147483647]
      ),
    )
  })
}

///|
/// A Mock that answers every Host, with a Stub for `GET /hello` and one
/// that takes uploads.
let hello_and_uploads : String =
  #|{ "mocks": [{ "name": "files" }],
  #|  "stubs": [
  #|    { "id": "hello", "mock": "files",
  #|      "request": { "method": "GET", "path": "/hello" },
  #|      "response": { "status": 200, "body": "hi" } },
  #|    { "id": "upload", "mock": "files",
  #|      "request": { "method": "POST", "path": "/upload" },
  #|      "response": { "status": 201, "body": "stored" } }] }

///|
/// The size of the header list `fields` as RFC 7541, section 4.1, counts
/// it: each field's name and value, in octets, plus 32.
fn list_size(fields : Array[(String, String)]) -> Int32 {
  let mut size = 0
  for field in fields {
    size += @utf8.encode(field.0).length() + @utf8.encode(field.1).length() + 32
  }
  size
}

///|
/// `fields`, then an `x-pad` field whose value of `a`s makes the list
/// `size` octets as RFC 7541, section 4.1, counts it.
fn padded(
  fields : Array[(String, String)],
  size : Int32,
) -> Array[(String, String)] {
  let pad = size - list_size(fields) - "x-pad".length() - 32
  [..fields, ("x-pad", String::make(pad, 'a'))]
}

///|
/// The Journal's entries, one per line, as `<method> <target>`.
async fn journaled(smock : Smock) -> String {
  let (_, journal) = smock.journal()
  guard journal is Object({ "entries": Array(entries), .. }) else {
    fail("no entries: \{journal.stringify()}")
  }
  let out = []
  for entry in entries {
    guard entry
      is Object(
        {
          "request": Object(
            { "method": String(meth), "target": String(target), .. }
          ),
          ..
        }
      ) else {
      fail("an entry without a request: \{entry.stringify()}")
    }
    out.push("\{meth} \{target}")
  }
  out.join("\n")
}

///|
async test "h2c: a header list just over --header-size-limit, counted as RFC 7541 counts it with every cookie field, gets 431 on its stream while a concurrent stream is answered, one at the limit is served, and the 431 is rejected traffic with no Journal entry" {
  with_definitions([("files.json", hello_and_uploads)], dir => {
    let args = ["--dir", dir, "--port", "0", "--header-size-limit", "1000"]
    let _ = with_smock(args, smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let hello = request_fields("GET", "/hello", "localhost")
      let at_limit = padded(hello, 1000)
      let over = padded(hello, 1001)
      // Two cookie fields, which smock joins into one of 46 octets, 36 less
      // than the two as received.
      let cookies = padded(
        [..hello, ("cookie", "a=1"), ("cookie", "b=2")],
        1001,
      )
      let out = [
        "Stream 1 uploads; stream 3 sends a list of \{list_size(at_limit)} octets, stream 5 one of \{list_size(over)}, stream 7 one of \{list_size(cookies)} with two cookie fields:",
      ]
      raw.send([
        headers_frame(
          1,
          raw.block(request_fields("POST", "/upload", "localhost")),
          end_stream=false,
        ),
        headers_frame(3, raw.block(at_limit)),
        headers_frame(5, raw.block(over)),
        headers_frame(7, raw.block(cookies)),
        Data(stream_id=1, data=b"abc", end_stream=true, padding=0),
      ])
      out.push(raw.frames_until_stream_ends(1))
      // Over HTTP/1.1, the head with the regular fields of stream 5 fits.
      let conn = smock.connect()
      defer conn.close()
      let head = raw_request(
        "GET",
        "/hello",
        host="localhost",
        headers=over[4:].to_owned(),
      )
      conn.write(head)
      let (status, _) = http1_status_and_body(conn)
      out.push(
        "Over HTTP/1.1, a head of \{head.length()} octets with the same fields: \{status}",
      )
      out.push("Journal:")
      out.push(journaled(smock))
      out.push(smock.metric("smock_requests_total"))
      inspect(
        out.join("\n"),
        content=(
          #|Stream 1 uploads; stream 3 sends a list of 1000 octets, stream 5 one of 1001, stream 7 one of 1001 with two cookie fields:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=2000]
          #|SETTINGS ACK
          #|HEADERS 3 END_HEADERS [:status: 200, smock-mock: files; via=default, date: <now>, content-length: 2]
          #|DATA 3 END_STREAM 2 octets
          #|HEADERS 5 END_STREAM END_HEADERS [:status: 431, date: <now>, content-length: 0]
          #|HEADERS 7 END_STREAM END_HEADERS [:status: 431, date: <now>, content-length: 0]
          #|HEADERS 1 END_HEADERS [:status: 201, smock-mock: files; via=default, date: <now>, content-length: 6]
          #|DATA 1 END_STREAM 6 octets
          #|Over HTTP/1.1, a head of 834 octets with the same fields: 200
          #|Journal:
          #|GET /hello
          #|POST /upload
          #|GET /hello
          #|smock_requests_total{mock="files",stub="hello"} 2
          #|smock_requests_total{mock="",stub=""} 2
          #|smock_requests_total{mock="files",stub="upload"} 1
        ),
      )
    })
  })
}

///|
async test "h2c: a header list with more regular fields than --header-count-limit gets 431 on its stream, where pseudo-header fields do not count and cookie fields split across several count as one" {
  with_definitions([("files.json", hello_and_uploads)], dir => {
    let args = ["--dir", dir, "--port", "0", "--header-count-limit", "3"]
    let _ = with_smock(args, smock => {
      let client = smock.h2c()
      defer client.close()
      let out = []
      for
        case in [
          ("three fields", [("x-a", "1"), ("x-b", "2"), ("x-c", "3")]),
          (
            "four fields",
            [("x-a", "1"), ("x-b", "2"), ("x-c", "3"), ("x-d", "4")],
          ),
          (
            "two fields and three cookie fields",
            [
              ("x-a", "1"),
              ("cookie", "a=1"),
              ("x-b", "2"),
              ("cookie", "b=2"),
              ("cookie", "c=3"),
            ],
          ),
          (
            "three fields and two cookie fields",
            [
              ("x-a", "1"),
              ("cookie", "a=1"),
              ("x-b", "2"),
              ("x-c", "3"),
              ("cookie", "b=2"),
            ],
          ),
        ] {
        let (label, headers) = case
        let response = client.request(
          "GET",
          "/hello",
          authority="localhost",
          headers~,
        )
        out.push("\{label}: \{response.line()}")
      }
      let (_, journal) = smock.journal()
      guard journal is Object({ "entries": Array(entries), .. }) else {
        fail("no entries: \{journal.stringify()}")
      }
      for entry in entries {
        guard entry
          is Object({ "request": Object({ "headers": headers, .. }), .. }) else {
          fail("an entry without headers: \{entry.stringify()}")
        }
        out.push("Journal: \{headers.stringify()}")
      }
      inspect(
        out.join("\n"),
        content=(
          #|three fields: 200 [smock-mock: files; via=default, date: <now>, content-length: 2] 2 octets, end
          #|four fields: 431 [date: <now>, content-length: 0] 0 octets, end
          #|two fields and three cookie fields: 200 [smock-mock: files; via=default, date: <now>, content-length: 2] 2 octets, end
          #|three fields and two cookie fields: 431 [date: <now>, content-length: 0] 0 octets, end
          #|Journal: [{"name":"x-a","value":"1"},{"name":"x-b","value":"2"},{"name":"x-c","value":"3"}]
          #|Journal: [{"name":"x-a","value":"1"},{"name":"cookie","value":"a=1; b=2; c=3"},{"name":"x-b","value":"2"}]
        ),
      )
    })
  })
}
