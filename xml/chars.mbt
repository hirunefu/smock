///|
/// Decodes the UTF-8 character that starts at byte `pos` of `input`, and
/// returns its code point and its length in bytes packed in one `Int`, as
/// `code_point(decoded)` and `byte_length(decoded)` read them, or -1 when
/// the bytes there are not well-formed UTF-8.
///
/// The result is packed, rather than a tuple, and the bytes are checked
/// with plain functions, rather than a local closure, so that decoding
/// allocates nothing: it runs for every character of a request body.
fn decode(input : BytesView, pos : Int) -> Int {
  let b0 = input[pos].to_int()
  if b0 < 0x80 {
    return packed(b0, 1)
  }
  if b0 >= 0xC2 && b0 <= 0xDF {
    let c1 = continuation(input, pos + 1, 0x80, 0xBF)
    if c1 >= 0 {
      return packed(((b0 & 0x1F) << 6) | c1, 2)
    }
  } else if b0 >= 0xE0 && b0 <= 0xEF {
    // E0 excludes overlong forms, ED the surrogates.
    let lo = if b0 == 0xE0 { 0xA0 } else { 0x80 }
    let hi = if b0 == 0xED { 0x9F } else { 0xBF }
    let c1 = continuation(input, pos + 1, lo, hi)
    let c2 = if c1 >= 0 { continuation(input, pos + 2, 0x80, 0xBF) } else { -1 }
    if c2 >= 0 {
      return packed(((b0 & 0x0F) << 12) | (c1 << 6) | c2, 3)
    }
  } else if b0 >= 0xF0 && b0 <= 0xF4 {
    // F0 excludes overlong forms, F4 code points past U+10FFFF.
    let lo = if b0 == 0xF0 { 0x90 } else { 0x80 }
    let hi = if b0 == 0xF4 { 0x8F } else { 0xBF }
    let c1 = continuation(input, pos + 1, lo, hi)
    let c2 = if c1 >= 0 { continuation(input, pos + 2, 0x80, 0xBF) } else { -1 }
    let c3 = if c2 >= 0 { continuation(input, pos + 3, 0x80, 0xBF) } else { -1 }
    if c3 >= 0 {
      return packed(((b0 & 0x07) << 18) | (c1 << 12) | (c2 << 6) | c3, 4)
    }
  }
  -1
}

///|
/// The payload bits of the continuation byte at `i` of `input`, or -1 when
/// there is none or it is not between `lo` and `hi`.
fn continuation(input : BytesView, i : Int, lo : Int, hi : Int) -> Int {
  if i >= input.length() {
    return -1
  }
  let b = input[i].to_int()
  if b < lo || b > hi {
    -1
  } else {
    b & 0x3F
  }
}

///|
/// A code point and its length in UTF-8, 1 to 4, packed as `decode`
/// returns them.
fn packed(code_point : Int, length : Int) -> Int {
  (code_point << 3) | length
}

///|
/// The code point of a character `decode` returned.
fn code_point(decoded : Int) -> Int {
  decoded >> 3
}

///|
/// The length in bytes of a character `decode` returned.
fn byte_length(decoded : Int) -> Int {
  decoded & 7
}

///|
/// Whether `c` is a character XML allows (XML 1.0 §2.2 [2]).
fn is_char(c : Int) -> Bool {
  c is (0x9 | 0xA | 0xD | 0x20..=0xD7FF | 0xE000..=0xFFFD | 0x10000..=0x10FFFF)
}

///|
/// Whether `c` is XML whitespace (XML 1.0 §2.3 [3]): space, tab, line feed
/// or carriage return.
fn is_space(c : Int) -> Bool {
  c is (0x20 | 0x9 | 0xA | 0xD)
}

///|
/// Whether `c` may start a name (XML 1.0 §2.3 [4]).
fn is_name_start(c : Int) -> Bool {
  c
  is (':'
  | 'A'..='Z'
  | '_'
  | 'a'..='z'
  | 0xC0..=0xD6
  | 0xD8..=0xF6
  | 0xF8..=0x2FF
  | 0x370..=0x37D
  | 0x37F..=0x1FFF
  | 0x200C..=0x200D
  | 0x2070..=0x218F
  | 0x2C00..=0x2FEF
  | 0x3001..=0xD7FF
  | 0xF900..=0xFDCF
  | 0xFDF0..=0xFFFD
  | 0x10000..=0xEFFFF)
}

///|
/// Whether `c` may continue a name (XML 1.0 §2.3 [4a]).
fn is_name_char(c : Int) -> Bool {
  is_name_start(c) ||
  c is ('-' | '.' | '0'..='9' | 0xB7 | 0x300..=0x36F | 0x203F..=0x2040)
}

///|
/// The character that the predefined entity `name` stands for (XML 1.0
/// §4.6), or -1 when it is none of them.
fn predefined_entity(name : BytesView) -> Int {
  match name {
    [b'l', b't'] => '<'
    [b'g', b't'] => '>'
    [b'a', b'm', b'p'] => '&'
    [b'a', b'p', b'o', b's'] => '\''
    [b'q', b'u', b'o', b't'] => '"'
    _ => -1
  }
}

///|
/// The index of the first colon of `input` from byte `start` to byte `end`,
/// or -1.
fn find_colon(input : BytesView, start : Int, end : Int) -> Int {
  for i in start..<end {
    if input[i] == b':' {
      return i
    }
  }
  -1
}

///|
/// Where the local name of the qualified name of `input` from byte `start`
/// to byte `end` starts: after its colon, if it has one (Namespaces in XML
/// 1.0 §4).
fn local_start(input : BytesView, start : Int, end : Int) -> Int {
  let colon = find_colon(input, start, end)
  if colon < 0 {
    start
  } else {
    colon + 1
  }
}
