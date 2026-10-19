// Input is UTF-8 and is matched by code point. A byte that is not part of a
// well-formed UTF-8 sequence is not a character: nothing that consumes a
// character (a literal, `.`, a class) matches it, so no match contains it,
// but matching goes on around it without an error.

///|
/// Shows the leftmost match of `pattern` in `input` and whether it matches
/// the whole input, as `search <start-end|none>, full <bool>`.
fn on_bytes(pattern : String, input : Bytes) -> String {
  let re = @re2.compile(pattern) catch { e => return e.to_string() }
  "search \{show_match(re.search(input[:]))}, full \{re.full_match(input[:])}"
}

///|
/// `on_bytes` with the UTF-8 encoding of `input`.
fn on(pattern : String, input : String) -> String {
  on_bytes(pattern, @utf8.encode(input))
}

///|
test "classes and . consume one code point of any length" {
  inspect(on("^.$", "é"), content="search 0-2, full true")
  inspect(on("^.$", "€"), content="search 0-3, full true")
  inspect(on("^.$", "😀"), content="search 0-4, full true")
  inspect(on("^..$", "é"), content="search none, full false")
  inspect(on("[^a]", "😀"), content="search 0-4, full true")
  inspect(on("\\W+", "a€😀b"), content="search 1-8, full false")
  inspect(on("€", "a€b"), content="search 1-4, full false")
  inspect(on("[€-€]", "€"), content="search 0-3, full true")
}

///|
test "bytes that are not well-formed UTF-8 match nothing that consumes a character" {
  // The same results as RE2.
  inspect(on_bytes(".", b"\xff"), content="search none, full false")
  inspect(on_bytes("(?s).", b"\xff"), content="search none, full false")
  inspect(on_bytes("[^a]", b"\xff"), content="search none, full false")
  inspect(on_bytes("\\W", b"\xff"), content="search none, full false")
  inspect(on_bytes("\\D", b"\xff"), content="search none, full false")
  inspect(on_bytes("\\S", b"\xff"), content="search none, full false")
  inspect(on_bytes(".", b"\x80"), content="search none, full false")
  inspect(on_bytes("..", b"\xc3\xa9"), content="search none, full false")
  inspect(on_bytes(".", b"\xc3"), content="search none, full false")
  inspect(on_bytes(".", b"\xe2\x84"), content="search none, full false")
  inspect(on_bytes("(?s).", b"\xc0\x80"), content="search none, full false")
  inspect(on_bytes("\u{FFFD}", b"\xff"), content="search none, full false")
}

///|
test "matching goes on around bytes that are not well-formed UTF-8" {
  // The same results as RE2.
  inspect(on_bytes("c+", b"ab\xffccd"), content="search 3-5, full false")
  inspect(on_bytes("b.c", b"ab\xffcd"), content="search none, full false")
  inspect(on_bytes("(?s).*", b"ab\xffcd"), content="search 0-2, full false")
  inspect(on_bytes("(?s).+", b"\xffab\xfe"), content="search 1-3, full false")
  inspect(on_bytes("a", b"\xc3a"), content="search 1-2, full false")
  inspect(on_bytes("", b"\xff"), content="search 0-0, full false")
  inspect(on_bytes("$", b"\xff"), content="search 1-1, full false")
  inspect(on_bytes("x*", b"\xff"), content="search 0-0, full false")
  inspect(on_bytes("a\\b", b"a\xff"), content="search 0-1, full false")
  inspect(on_bytes("\\b", b"\xffa"), content="search 1-1, full false")
  inspect(on_bytes("\\B", b"\xff"), content="search 0-0, full false")
}

///|
test "every byte and byte pair is matched without an error" {
  let patterns = [
    ".", "(?s).*", "[^a]", "\\W", "\\b", "\\B", "x*", "(?m)^", "(?m)$", "é",
  ].map(p => @re2.compile(p))
  for b0 in 0..<256 {
    let one = Bytes::from_array([b0.to_byte()])
    // A single byte is a character exactly when it is ASCII.
    let any = @re2.compile("(?s).").full_match(one[:])
    assert_eq(any, b0 < 0x80)
    for b1 in 0..<256 {
      let two = Bytes::from_array([b0.to_byte(), b1.to_byte()])
      for re in patterns {
        ignore(re.search(two[:]))
        ignore(re.full_match(two[:]))
      }
    }
  }
}

///|
test "where smock's RE2 subset differs from RE2 on input that is not well-formed UTF-8" {
  // RE2 reads these as one character: an overlong encoding, a surrogate
  // and a code point past U+10FFFF. The subset reads only well-formed
  // UTF-8, so each of their bytes is not a character.
  inspect(on_bytes("(?s).", b"\xe0\x80\x80"), content="search none, full false")
  inspect(on_bytes("(?s).", b"\xed\xa0\x80"), content="search none, full false")
  inspect(
    on_bytes("(?s).", b"\xf4\x90\x80\x80"),
    content="search none, full false",
  )
  // RE2 can find an empty match inside a multi-byte character (here 2-2,
  // between the two bytes of é). The subset matches at code point
  // boundaries only.
  inspect(on("\\B", "aé"), content="search 3-3, full false")
}

///|
test "(?i) folds ASCII letters only" {
  // Unicode case folding is not in the subset: RE2 would also match É for
  // é, and the Kelvin sign K (U+212A) for k.
  inspect(on("(?i)é", "É"), content="search none, full false")
  inspect(on("(?i)é", "é"), content="search 0-2, full true")
  inspect(on("(?i)k", "\u{212A}"), content="search none, full false")
  inspect(on("(?i)[à-ä]", "Â"), content="search none, full false")
}
