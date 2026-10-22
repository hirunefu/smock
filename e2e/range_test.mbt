// Seam 2 tests of Range requests: a 206 and a 416 on the wire, framed by
// the Content-Length of what they send, and a partial Fault on a 206.

///|
/// Mock `media` with `GET /video.mp4`, which answers 200 from the body file
/// `video.mp4`, and `GET /cut.mp4`, which answers the same with a partial
/// Fault.
let media_definitions : String =
  #|mocks:
  #|  - name: media
  #|stubs:
  #|  - id: get-video
  #|    mock: media
  #|    request: { method: GET, path: /video.mp4 }
  #|    response:
  #|      status: 200
  #|      headers: { Content-Type: video/mp4 }
  #|      bodyFile: video.mp4
  #|  - id: cut-video
  #|    mock: media
  #|    request: { method: GET, path: /cut.mp4 }
  #|    response:
  #|      status: 200
  #|      headers: { Content-Type: video/mp4 }
  #|      bodyFile: video.mp4
  #|    fault: { connection: { kind: partial } }

///|
/// The definitions directory of `media_definitions`, with the 26 letters
/// as `video.mp4`.
let media_files : Array[(String, String)] = [
  ("media.yaml", media_definitions),
  ("files/video.mp4", "abcdefghijklmnopqrstuvwxyz"),
]

///|
async test "a byte range gets 206 and an unsatisfiable one 416, each framed by the Content-Length of what it sends, on one connection" {
  let _ = on_both_ports(files=media_files, (smock, over) => {
    let conn = smock.connect(over~)
    defer conn.close()
    let out = []
    for range in ["bytes=0-99", "bytes=-5", "bytes=26-", ""] {
      let headers = if range == "" { [] } else { [("Range", range)] }
      conn.write(raw_request("GET", "/video.mp4", host="localhost", headers~))
      out.push(read_response(conn))
    }
    inspect(
      out.join("\n---\n"),
      content=(
        #|HTTP/1.1 206 Partial Content
        #|Content-Type: video/mp4
        #|Content-Range: bytes 0-25/26
        #|Accept-Ranges: bytes
        #|Smock-Mock: media; via=default
        #|Content-Length: 26
        #|
        #|abcdefghijklmnopqrstuvwxyz
        #|---
        #|HTTP/1.1 206 Partial Content
        #|Content-Type: video/mp4
        #|Content-Range: bytes 21-25/26
        #|Accept-Ranges: bytes
        #|Smock-Mock: media; via=default
        #|Content-Length: 5
        #|
        #|vwxyz
        #|---
        #|HTTP/1.1 416 Range Not Satisfiable
        #|Content-Type: video/mp4
        #|Content-Range: bytes */26
        #|Smock-Mock: media; via=default
        #|Content-Length: 0
        #|
        #|
        #|---
        #|HTTP/1.1 200 OK
        #|Content-Type: video/mp4
        #|Accept-Ranges: bytes
        #|Smock-Mock: media; via=default
        #|Content-Length: 26
        #|
        #|abcdefghijklmnopqrstuvwxyz
      ),
    )
  })
}

///|
async test "a partial Fault on a 206 sends the head, with the 206's Content-Length, and the first half of the range, then a FIN" {
  let _ = on_both_ports(files=media_files, (smock, over) => {
    let conn = smock.connect(over~)
    defer conn.close()
    conn.write(
      raw_request("GET", "/cut.mp4", host="localhost", headers=[
        ("Range", "bytes=10-19"),
      ]),
    )
    inspect(
      read_to_end(conn),
      content=(
        #|HTTP/1.1 206 Partial Content
        #|Content-Type: video/mp4
        #|Content-Range: bytes 10-19/26
        #|Accept-Ranges: bytes
        #|Smock-Mock: media; via=default
        #|Content-Length: 10
        #|
        #|klmno
      ),
    )
  })
}
