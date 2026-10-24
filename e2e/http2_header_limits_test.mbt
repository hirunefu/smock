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
