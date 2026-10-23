// Adversarial input for the public checks that HTTP/2 shares with the
// HTTP/1.1 parser: the request target's form and characters, the Host
// value, the token and the field value.

///|
/// The octets from 0x00 to 0xFF for which `accepts` holds, as ranges such
/// as `21-7e`. Each octet is given as the character with its value.
fn accepted_octets(accepts : (Int) -> Bool) -> String {
  let ranges = []
  let mut first : Int? = None
  for octet in 0..<=256 {
    let ok = octet < 256 && accepts(octet)
    match (first, ok) {
      (None, true) => first = Some(octet)
      (Some(from), false) => {
        let to = octet - 1
        ranges.push(
          if from == to {
            from.to_string(radix=16)
          } else {
            "\{from.to_string(radix=16)}-\{to.to_string(radix=16)}"
          },
        )
        first = None
      }
      _ => ()
    }
  }
  ranges.join(" ")
}

///|
/// The character with the value `octet`.
fn octet_char(octet : Int) -> String {
  Int::unsafe_to_char(octet).to_string()
}

///|
test "the visible-ASCII rule accepts the octets 0x21 to 0x7e alone, wherever they are" {
  inspect(
    accepted_octets(octet => @http1.is_visible_ascii(octet_char(octet))),
    content="21-7e",
  )
  inspect(
    accepted_octets(octet => {
      @http1.is_visible_ascii("/users/1?x=\{octet_char(octet)}&y=abcdefghijk")
    }),
    content="21-7e",
  )
}

///|
/// Whether the parser takes out a GET request whose target is `target`,
/// written as one byte per character.
fn parses_target(target : String) -> Bool {
  let head = @buffer.Buffer()
  head.write_bytes(b"GET ")
  for i in 0..<target.length() {
    head.write_byte(target[i].to_byte())
  }
  head.write_bytes(b" HTTP/1.1\r\nHost: a.example\r\n\r\n")
  let parser = @http1.Parser()
  parser.feed(head.to_bytes())
  parser.next() is Complete(_)
}

///|
test "the parser takes every visible octet in a target but `#`, short or long, and refuses the others" {
  // A space ends the target, and `#` starts a fragment, which no target
  // has.
  inspect(
    accepted_octets(octet => parses_target("/\{octet_char(octet)}")),
    content="21-22 24-7e",
  )
  // Past the first eight bytes, where the head scan takes eight at a time.
  inspect(
    accepted_octets(octet => {
      parses_target("/users/1?x=abcdefghijk\{octet_char(octet)}lmnopqrstu")
    }),
    content="21-22 24-7e",
  )
}

///|
test "the origin-form check takes a path and query, or `*` alone for OPTIONS, and refuses the other forms" {
  let targets = [
    "/", "/users/1", "/users/1?x=y", "/?", "//a.example/users", "/*", "/a#b", "/#",
    "", "?x=y", "users/1", "*", "**", "*/", "* ", " *", "*?x", "*#", "x*", "http://a.example/users/1",
    "https://a.example", "a.example:443", "[::1]:8080", "a.example", "urn:x",
  ]
  let lines = []
  for target in targets {
    let verdicts = ["GET", "OPTIONS", "CONNECT"].map(meth => {
      "\{meth} \{@http1.is_origin_or_asterisk_form(target, meth~)}"
    })
    lines.push("\{shown(target)}: \{verdicts.join(", ")}")
  }
  inspect(
    lines.join("\n"),
    content=(
      #|"/": GET true, OPTIONS true, CONNECT false
      #|"/users/1": GET true, OPTIONS true, CONNECT false
      #|"/users/1?x=y": GET true, OPTIONS true, CONNECT false
      #|"/?": GET true, OPTIONS true, CONNECT false
      #|"//a.example/users": GET true, OPTIONS true, CONNECT false
      #|"/*": GET true, OPTIONS true, CONNECT false
      #|"/a#b": GET false, OPTIONS false, CONNECT false
      #|"/#": GET false, OPTIONS false, CONNECT false
      #|"": GET false, OPTIONS false, CONNECT false
      #|"?x=y": GET false, OPTIONS false, CONNECT false
      #|"users/1": GET false, OPTIONS false, CONNECT false
      #|"*": GET false, OPTIONS true, CONNECT false
      #|"**": GET false, OPTIONS false, CONNECT false
      #|"*/": GET false, OPTIONS false, CONNECT false
      #|"* ": GET false, OPTIONS false, CONNECT false
      #|" *": GET false, OPTIONS false, CONNECT false
      #|"*?x": GET false, OPTIONS false, CONNECT false
      #|"*#": GET false, OPTIONS false, CONNECT false
      #|"x*": GET false, OPTIONS false, CONNECT false
      #|"http://a.example/users/1": GET false, OPTIONS false, CONNECT false
      #|"https://a.example": GET false, OPTIONS false, CONNECT false
      #|"a.example:443": GET false, OPTIONS false, CONNECT false
      #|"[::1]:8080": GET false, OPTIONS false, CONNECT false
      #|"a.example": GET false, OPTIONS false, CONNECT false
      #|"urn:x": GET false, OPTIONS false, CONNECT false
    ),
  )
}

///|
test "`*` with any other octet before or after it is no target, but `/*` is a path" {
  inspect(
    accepted_octets(octet => {
      @http1.is_origin_or_asterisk_form("*\{octet_char(octet)}", meth="OPTIONS")
    }),
    content="",
  )
  inspect(
    accepted_octets(octet => {
      @http1.is_origin_or_asterisk_form("\{octet_char(octet)}*", meth="OPTIONS")
    }),
    content="2f",
  )
}

///|
test "a token takes the octets of RFC 9110's tchar alone, and a field value all but the controls other than tab, and DEL" {
  inspect(
    accepted_octets(octet => @http1.is_token(octet_char(octet))),
    content="21 23-27 2a-2b 2d-2e 30-39 41-5a 5e-7a 7c 7e",
  )
  inspect(
    accepted_octets(octet => @http1.is_token("Content-\{octet_char(octet)}Type")),
    content="21 23-27 2a-2b 2d-2e 30-39 41-5a 5e-7a 7c 7e",
  )
  // Octets above 0x7f stand for characters beyond ASCII, which a field
  // value takes and writes as UTF-8.
  inspect(
    accepted_octets(octet => @http1.is_field_value(octet_char(octet))),
    content="9 20-7e 80-ff",
  )
  inspect(
    accepted_octets(octet => {
      @http1.is_field_value("text/plain; \{octet_char(octet)}charset=utf-8")
    }),
    content="9 20-7e 80-ff",
  )
}

///|
test "a character beyond ASCII is no visible ASCII and no token, whatever its low byte, and a field value takes it" {
  // Each of these has a low byte that is visible ASCII, a tab or LF.
  let texts = [
    "\u{121}", "\u{17e}", "\u{ff21}", "\u{109}", "\u{10a}", "\u{1f600}",
  ]
  inspect(
    texts
    .map(text => {
      "\{shown(text)}: visible \{@http1.is_visible_ascii(text)}, token \{@http1.is_token(text)}, field value \{@http1.is_field_value(text)}"
    })
    .join("\n"),
    content=(
      #|"\u{121}": visible false, token false, field value true
      #|"\u{17e}": visible false, token false, field value true
      #|"\u{ff21}": visible false, token false, field value true
      #|"\u{109}": visible false, token false, field value true
      #|"\u{10a}": visible false, token false, field value true
      #|"\u{1f600}": visible false, token false, field value true
    ),
  )
}

///|
test "empty input is a field value, a Host value and visible ASCII, but no token and no target" {
  inspect(
    [
      "visible \{@http1.is_visible_ascii("")}",
      "origin or asterisk \{@http1.is_origin_or_asterisk_form("", meth="GET")}",
      "token \{@http1.is_token("")}",
      "field value \{@http1.is_field_value("")}",
      "host \{@http1.is_host_value("")}",
    ].join(", "),
    content=(
      #|visible true, origin or asterisk false, token false, field value true, host true
    ),
  )
}

///|
test "a Host value is a host and an optional port: names, IPv4 and IPv6 literals, trailing dots and bad octets" {
  let ports = [
    "a.example:8080", "a.example:", "a.example:0", "a.example:65536", ":80", "a.example:80a",
    "a.example:-1", "a.example: 80", "a.example:80:80", "a.example::80",
  ]
  // An IPv4 address out of range, or with a leading zero, is still a
  // registered name.
  let ipv4 = ["192.0.2.1", "192.0.2.1:80", "192.0.2.256", "192.0.02.1"]
  let ip_literals = [
    "[::1]", "[::1]:8080", "[2001:db8::1]", "[2001:db8:0:0:0:0:0:1]", "[::ffff:192.0.2.1]:443",
    "[v1.x]", "[V7.a:b]", "[::]", "::1", "[::1", "::1]", "[::1]x", "[::1]:", "[::1]:x",
    "[1:2:3:4:5:6:7:8:9]", "[1::2::3]", "[12345::1]", "[g::1]", "[::256.1.1.1]",
    "[192.0.2.1]", "[]", "[v.x]", "[v1.]",
  ]
  let trailing_dots = ["a.example.", "a.example.:80", "a..example", ".", ".."]
  let percent_encoded = ["a%41.example", "a%4.example", "a%zz.example", "a%"]
  let bad_octets = [
    "a example", "a\texample", "a\u{0}example", "a/example", "a@example", "a\\example",
    "caf\u{e9}.example", "a.example\r\nX: 1",
  ]
  let hosts = [
    ..ports, ..ipv4, ..ip_literals, ..trailing_dots, ..percent_encoded, ..bad_octets,
  ]
  inspect(
    hosts
    .map(host => "\{shown(host)}: \{@http1.is_host_value(host)}")
    .join("\n"),
    content=(
      #|"a.example:8080": true
      #|"a.example:": true
      #|"a.example:0": true
      #|"a.example:65536": true
      #|":80": true
      #|"a.example:80a": false
      #|"a.example:-1": false
      #|"a.example: 80": false
      #|"a.example:80:80": false
      #|"a.example::80": false
      #|"192.0.2.1": true
      #|"192.0.2.1:80": true
      #|"192.0.2.256": true
      #|"192.0.02.1": true
      #|"[::1]": true
      #|"[::1]:8080": true
      #|"[2001:db8::1]": true
      #|"[2001:db8:0:0:0:0:0:1]": true
      #|"[::ffff:192.0.2.1]:443": true
      #|"[v1.x]": true
      #|"[V7.a:b]": true
      #|"[::]": true
      #|"::1": false
      #|"[::1": false
      #|"::1]": false
      #|"[::1]x": false
      #|"[::1]:": true
      #|"[::1]:x": false
      #|"[1:2:3:4:5:6:7:8:9]": false
      #|"[1::2::3]": false
      #|"[12345::1]": false
      #|"[g::1]": false
      #|"[::256.1.1.1]": false
      #|"[192.0.2.1]": false
      #|"[]": false
      #|"[v.x]": false
      #|"[v1.]": false
      #|"a.example.": true
      #|"a.example.:80": true
      #|"a..example": true
      #|".": true
      #|"..": true
      #|"a%41.example": true
      #|"a%4.example": false
      #|"a%zz.example": false
      #|"a%": false
      #|"a example": false
      #|"a\texample": false
      #|"a\u{00}example": false
      #|"a/example": false
      #|"a@example": false
      #|"a\\example": false
      #|"caf\u{e9}.example": false
      #|"a.example\r\nX: 1": false
    ),
  )
  // A registered name takes unreserved characters and sub-delims, and `%`
  // only before two hexadecimal digits.
  inspect(
    accepted_octets(octet => {
      @http1.is_host_value("a\{octet_char(octet)}b.example:443")
    }),
    content=(
      #|21 24 26-2e 30-39 3b 3d 41-5a 5f 61-7a 7e
    ),
  )
}
