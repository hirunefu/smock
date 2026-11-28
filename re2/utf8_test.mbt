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
  // The first and last code point of each kind of well-formed sequence of
  // one to three bytes that RFC 3629, section 4, lists (UTF8-1, UTF8-2 and
  // the four kinds of UTF8-3, around the surrogates U+D800 to U+DFFF, which
  // UTF-8 does not encode). The same results as RE2.
  inspect(on("^.$", "\u{0}"), content="search 0-1, full true")
  inspect(on("^.$", "\u{7F}"), content="search 0-1, full true")
  inspect(on("^.$", "\u{80}"), content="search 0-2, full true")
  inspect(on("^.$", "\u{7FF}"), content="search 0-2, full true")
  inspect(on("^.$", "\u{800}"), content="search 0-3, full true")
  inspect(on("^.$", "\u{FFF}"), content="search 0-3, full true")
  inspect(on("^.$", "\u{1000}"), content="search 0-3, full true")
  inspect(on("^.$", "\u{CFFF}"), content="search 0-3, full true")
  inspect(on("^.$", "\u{D000}"), content="search 0-3, full true")
  inspect(on("^.$", "\u{D7FF}"), content="search 0-3, full true")
  inspect(on("^.$", "\u{E000}"), content="search 0-3, full true")
  inspect(on("^.$", "\u{FFFF}"), content="search 0-3, full true")
  // The first and last code point of each of the three kinds of well-formed
  // sequence of four bytes that RFC 3629, section 4, lists in UTF8-4 (F0
  // then 90 to BF, F1 to F3 then 80 to BF, F4 then 80 to 8F, each followed
  // by two bytes of 80 to BF). The same results as RE2.
  inspect(on("^.$", "\u{10000}"), content="search 0-4, full true")
  inspect(on("^.$", "\u{3FFFF}"), content="search 0-4, full true")
  inspect(on("^.$", "\u{40000}"), content="search 0-4, full true")
  inspect(on("^.$", "\u{FFFFF}"), content="search 0-4, full true")
  inspect(on("^.$", "\u{100000}"), content="search 0-4, full true")
  inspect(on("^.$", "\u{10FFFF}"), content="search 0-4, full true")
  // Each is the code point its four bytes encode, so a literal of it matches
  // it. The same results as RE2.
  inspect(on("\u{10000}", "\u{10000}"), content="search 0-4, full true")
  inspect(on("\u{3FFFF}", "\u{3FFFF}"), content="search 0-4, full true")
  inspect(on("\u{40000}", "\u{40000}"), content="search 0-4, full true")
  inspect(on("\u{FFFFF}", "\u{FFFFF}"), content="search 0-4, full true")
  inspect(on("\u{100000}", "\u{100000}"), content="search 0-4, full true")
  inspect(on("\u{10FFFF}", "\u{10FFFF}"), content="search 0-4, full true")
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
  // One byte off a well-formed sequence of RFC 3629, section 4: C1, just
  // below UTF8-2's first lead byte C2, and C0, just above the range a byte
  // after a lead byte may take (A0 to BF after E0, 80 to BF otherwise), as
  // the second byte of a sequence of two and of three bytes and as the third
  // byte of three. The same results as RE2.
  inspect(on_bytes("(?s).", b"\xc1\xbf"), content="search none, full false")
  inspect(on_bytes("(?s).", b"\xc2\xc0"), content="search none, full false")
  inspect(on_bytes("(?s).", b"\xe0\xc0\x80"), content="search none, full false")
  inspect(on_bytes("(?s).", b"\xe1\xc0\x80"), content="search none, full false")
  inspect(on_bytes("(?s).", b"\xe1\x80\xc0"), content="search none, full false")
  // One byte off a well-formed sequence of four bytes of RFC 3629, section
  // 4: C0, just above the range a byte after a lead byte may take (90 to BF
  // after F0, 80 to BF after F1 to F3), as the second byte after F0 and F1
  // and as the third and fourth byte; F5, just above UTF8-4's last lead
  // byte F4; and four bytes 80, which only follow a lead byte. The same
  // results as RE2.
  inspect(
    on_bytes("(?s).", b"\xf0\xc0\x80\x80"),
    content="search none, full false",
  )
  inspect(
    on_bytes("(?s).", b"\xf1\xc0\x80\x80"),
    content="search none, full false",
  )
  inspect(
    on_bytes("(?s).", b"\xf1\x80\xc0\x80"),
    content="search none, full false",
  )
  inspect(
    on_bytes("(?s).", b"\xf1\x80\x80\xc0"),
    content="search none, full false",
  )
  inspect(
    on_bytes("(?s).", b"\xf5\x80\x80\x80"),
    content="search none, full false",
  )
  inspect(
    on_bytes("(?s).", b"\x80\x80\x80\x80"),
    content="search none, full false",
  )
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
  // A lead byte of three bytes, then a character where a continuation byte
  // must come (RFC 3629, section 4), then a continuation byte: the lead
  // byte alone is not a character, and the character after it is found.
  // The same result as RE2.
  inspect(on_bytes("a", b"\xe1a\x80"), content="search 1-2, full false")
  // The same with a lead byte of four bytes, the character as the second,
  // third or fourth byte: no byte before the character is part of a
  // well-formed sequence, and the character is found. The same results as
  // RE2.
  inspect(on_bytes("a", b"\xf1a\x80\x80"), content="search 1-2, full false")
  inspect(on_bytes("a", b"\xf1\x80a\x80"), content="search 2-3, full false")
  inspect(on_bytes("a", b"\xf1\x80\x80a"), content="search 3-4, full false")
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
