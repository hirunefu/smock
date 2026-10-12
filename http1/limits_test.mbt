// Limits on header size, header count and body size, at their boundaries:
// exactly at the limit, and one over.

///|
/// A request head of exactly `size` bytes, request line and final empty line
/// included, with a Host field and one padding field.
fn head_of_size(size : Int) -> String {
  // "GET / HTTP/1.1\r\n" + "Host: a\r\n" + "X: " + padding + "\r\n" + "\r\n"
  "GET / HTTP/1.1\r\nHost: a\r\nX: \{"p".repeat(size - 32)}\r\n\r\n"
}

///|
/// What `parser` makes of `stream` fed whole: each request it takes out
/// (method, target and body length), then how it ends.
fn limited(parser : @http1.Parser, stream : String) -> String {
  parser.feed(@utf8.encode(stream))
  let out = []
  for ;; {
    match parser.next() {
      Complete(request) =>
        out.push(
          "\{request.meth} \{request.target} body=\{request.body.length()}",
        )
      Continue => out.push("continue")
      NeedMore => break out.push("need more")
      Invalid(status~) => break out.push("invalid \{status}")
    }
  }
  out.join(", ")
}

///|
test "a request head over the header size limit gets 431; the limit counts the request line, the header fields and the empty line that ends them" {
  inspect(
    [
      limited(@http1.Parser(), head_of_size(16 * 1024)),
      limited(@http1.Parser(), head_of_size(16 * 1024 + 1)),
      limited(@http1.Parser(header_size_limit=64), head_of_size(64)),
      limited(@http1.Parser(header_size_limit=64), head_of_size(65)),
      // The request line counts.
      limited(
        @http1.Parser(header_size_limit=64),
        "GET /\{"t".repeat(46)} HTTP/1.0\r\n\r\n",
      ),
      limited(
        @http1.Parser(header_size_limit=64),
        "GET /\{"t".repeat(47)} HTTP/1.0\r\n\r\n",
      ),
    ].join("\n"),
    content=(
      #|GET / body=0, need more
      #|invalid 431
      #|GET / body=0, need more
      #|invalid 431
      #|GET /tttttttttttttttttttttttttttttttttttttttttttttt body=0, need more
      #|invalid 431
    ),
  )
}

///|
test "a request head gets 431 as soon as it grows past the header size limit, without waiting for its end" {
  let head = head_of_size(65)
  inspect(
    limited(@http1.Parser(header_size_limit=64), head[:64].to_owned()) +
    "\n" +
    limited(@http1.Parser(header_size_limit=64), head[:65].to_owned()),
    content=(
      #|need more
      #|invalid 431
    ),
  )
}

///|
/// A request head with `count` header fields, Host among them.
fn head_with_fields(count : Int) -> String {
  let fields = (1).until(count).map(i => "X-\{i}: \{i}\r\n").collect()
  "GET / HTTP/1.1\r\nHost: a\r\n\{fields.join("")}\r\n"
}

///|
test "a request with more header fields than the header count limit gets 431" {
  inspect(
    [
      limited(@http1.Parser(), head_with_fields(100)),
      limited(@http1.Parser(), head_with_fields(101)),
      limited(@http1.Parser(header_count_limit=3), head_with_fields(3)),
      limited(@http1.Parser(header_count_limit=3), head_with_fields(4)),
      limited(@http1.Parser(header_count_limit=1), head_with_fields(1)),
      limited(@http1.Parser(header_count_limit=1), head_with_fields(2)),
    ].join("\n"),
    content=(
      #|GET / body=0, need more
      #|invalid 431
      #|GET / body=0, need more
      #|invalid 431
      #|GET / body=0, need more
      #|invalid 431
    ),
  )
}

///|
test "a request gets 431 as soon as a header field over the header count limit begins, without waiting for the end of its head" {
  let head = head_with_fields(4)
  let fourth = head.find("X-3").unwrap_or(0)
  inspect(
    limited(@http1.Parser(header_count_limit=3), head[:fourth].to_owned()) +
    "\n" +
    limited(@http1.Parser(header_count_limit=3), head[:fourth + 1].to_owned()),
    content=(
      #|need more
      #|invalid 431
    ),
  )
}

///|
test "the header count limit applies to each request on its own" {
  inspect(
    limited(
      @http1.Parser(header_count_limit=3),
      head_with_fields(3) + head_with_fields(3) + head_with_fields(2),
    ),
    content="GET / body=0, GET / body=0, GET / body=0, need more",
  )
}

///|
test "the header size limit applies to each request on its own; empty lines before a request and its body do not count" {
  inspect(
    limited(
      @http1.Parser(header_size_limit=64),
      head_of_size(64) +
      "\r\n\r\n" +
      head_of_size(64) +
      "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 100\r\n\r\n\{"b".repeat(100)}",
    ),
    content="GET / body=0, GET / body=0, POST / body=100, need more",
  )
}

///|
/// The head of a POST request with the header fields `fields`.
fn post(fields : String) -> String {
  "POST /p HTTP/1.1\r\nHost: a\r\n\{fields}\r\n"
}

///|
test "a declared Content-Length over the body limit gets 413 once the head has arrived, before any of the body" {
  inspect(
    [
      limited(@http1.Parser(), post("Content-Length: 10485760\r\n")),
      limited(@http1.Parser(), post("Content-Length: 10485761\r\n")),
      limited(
        @http1.Parser(body_limit=16),
        post("Content-Length: 16\r\n") + "b".repeat(16),
      ),
      limited(@http1.Parser(body_limit=16), post("Content-Length: 17\r\n")),
      limited(@http1.Parser(body_limit=16), post("Content-Length: 17, 17\r\n")),
      limited(@http1.Parser(body_limit=0), post("Content-Length: 0\r\n")),
      limited(@http1.Parser(body_limit=0), post("Content-Length: 1\r\n")),
    ].join("\n"),
    content=(
      #|need more
      #|invalid 413
      #|POST /p body=16, need more
      #|invalid 413
      #|invalid 413
      #|POST /p body=0, need more
      #|invalid 413
    ),
  )
}

///|
test "a chunked body gets 413 as soon as a chunk size takes it past the body limit, before that chunk's data" {
  let chunked = post("Transfer-Encoding: chunked\r\n")
  inspect(
    [
      limited(
        @http1.Parser(body_limit=16),
        chunked + "10\r\n\{"b".repeat(16)}\r\n0\r\n\r\n",
      ),
      limited(@http1.Parser(body_limit=16), chunked + "11\r\n"),
      limited(
        @http1.Parser(body_limit=16),
        chunked + "a\r\n\{"b".repeat(10)}\r\n6\r\n\{"b".repeat(6)}\r\n0\r\n\r\n",
      ),
      limited(
        @http1.Parser(body_limit=16),
        chunked + "a\r\n\{"b".repeat(10)}\r\n7\r\n",
      ),
      limited(
        @http1.Parser(body_limit=16),
        chunked + "a\r\n\{"b".repeat(10)}\r\n7",
      ),
      limited(@http1.Parser(), chunked + "a00000\r\n"),
      limited(@http1.Parser(), chunked + "a00001\r\n"),
    ].join("\n"),
    content=(
      #|POST /p body=16, need more
      #|invalid 413
      #|POST /p body=16, need more
      #|invalid 413
      #|need more
      #|need more
      #|invalid 413
    ),
  )
}

///|
test "the body limit counts the body, not the chunk sizes, extensions and trailer fields that frame it" {
  let chunk = "1;\{"e".repeat(100)}=\{"v".repeat(100)}\r\nb\r\n"
  inspect(
    limited(
      @http1.Parser(body_limit=16),
      post("Transfer-Encoding: chunked\r\n") +
      chunk.repeat(16) +
      "00000000000000000000\r\n\{"X-T: t\r\n".repeat(200)}\r\n",
    ),
    content="POST /p body=16, need more",
  )
}

///|
/// What a parser made by `make` takes out of `stream` fed in pieces of at
/// most `piece` bytes, until it turns invalid, with the `need more` between
/// pieces left out.
fn fed_in_pieces(
  make : () -> @http1.Parser,
  stream : String,
  piece : Int,
) -> String {
  let parser = make()
  let bytes = @utf8.encode(stream)
  let out = []
  for offset = 0; offset < bytes.length(); offset = offset + piece {
    let end = if offset + piece < bytes.length() {
      offset + piece
    } else {
      bytes.length()
    }
    let step = limited(parser, @utf8.decode_lossy(bytes[offset:end]))
    if step.has_suffix("need more") {
      if step != "need more" {
        out.push(step[:step.length() - ", need more".length()].to_owned())
      }
    } else {
      out.push(step)
      return out.join(", ")
    }
  }
  out.push("need more")
  out.join(", ")
}

///|
test "a head that never ends, or a flood of tiny header fields, gets 431 once past the limits" {
  let make = () => @http1.Parser(header_size_limit=1024, header_count_limit=10)
  inspect(
    [
      fed_in_pieces(
        make,
        "GET / HTTP/1.1\r\nHost: a\r\nX: \{"x".repeat(100_000)}",
        100,
      ),
      fed_in_pieces(make, "GET /\{"x".repeat(100_000)}", 7),
      fed_in_pieces(
        make,
        "GET / HTTP/1.1\r\nHost: a\r\n\{"a:\r\n".repeat(1000)}",
        3,
      ),
      fed_in_pieces(
        make,
        "GET / HTTP/1.1\r\nHost: a\r\n\{"a:\r\n".repeat(9)}\r\n",
        3,
      ),
    ].join("\n"),
    content=(
      #|invalid 431
      #|invalid 431
      #|invalid 431
      #|GET / body=0, need more
    ),
  )
}

///|
test "endless chunk framing around a small body is decoded without counting toward the body limit" {
  let make = () => @http1.Parser(body_limit=16)
  let chunked = post("Transfer-Encoding: chunked\r\n")
  inspect(
    [
      fed_in_pieces(
        make,
        chunked + "5;\{"e".repeat(1_000_000)}\r\nhello\r\n0\r\n\r\n",
        4096,
      ),
      fed_in_pieces(
        make,
        chunked + "\{"0".repeat(1_000_000)}5\r\nhello\r\n0\r\n\r\n",
        4096,
      ),
      fed_in_pieces(
        make,
        chunked + "5\r\nhello\r\n0\r\n\{"X-T: t\r\n".repeat(100_000)}\r\n",
        4096,
      ),
      fed_in_pieces(make, chunked + "1\r\nb\r\n".repeat(17) + "0\r\n\r\n", 4096),
    ].join("\n"),
    content=(
      #|POST /p body=5, need more
      #|POST /p body=5, need more
      #|POST /p body=5, need more
      #|invalid 413
    ),
  )
}

///|
test "requests at and over the limits give the same outcome however they are split" {
  let make = () => {
    @http1.Parser(header_size_limit=80, header_count_limit=3, body_limit=16)
  }
  let streams = [
    head_of_size(80) + head_with_fields(3) + head_of_size(81),
    head_with_fields(3) + head_with_fields(4),
    post("Expect: 100-continue\r\nContent-Length: 16\r\n") +
    "b".repeat(16) +
    post("Content-Length: 17\r\n"),
    post("Transfer-Encoding: chunked\r\n") +
    "8\r\n\{"b".repeat(8)}\r\n8\r\n\{"b".repeat(8)}\r\n0\r\n\r\n" +
    post("Transfer-Encoding: chunked\r\n") +
    "8\r\n\{"b".repeat(8)}\r\n9\r\n",
  ]
  let differ = []
  let wholes = []
  for stream in streams {
    let whole = fed_in_pieces(make, stream, stream.length())
    wholes.push(whole)
    for piece in [1, 2, 3, 5, 7, 13] {
      if fed_in_pieces(make, stream, piece) != whole {
        differ.push((stream, piece))
      }
    }
  }
  debug_inspect(differ, content="[]")
  inspect(
    wholes.join("\n"),
    content=(
      #|GET / body=0, GET / body=0, invalid 431
      #|GET / body=0, invalid 431
      #|continue, POST /p body=16, invalid 413
      #|POST /p body=16, invalid 413
    ),
  )
}
