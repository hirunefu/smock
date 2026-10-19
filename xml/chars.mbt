///|
/// Decodes the UTF-8 character that starts at byte `pos` of `input`, and
/// returns its code point and its length in bytes, or `(-1, 1)` when the
/// bytes there are not well-formed UTF-8.
fn decode(input : BytesView, pos : Int) -> (Int, Int) {
  let len = input.length()
  let b0 = input[pos].to_int()
  if b0 < 0x80 {
    return (b0, 1)
  }
  fn cont(i : Int, lo : Int, hi : Int) -> Int {
    if i >= len {
      return -1
    }
    let b = input[i].to_int()
    if b < lo || b > hi {
      -1
    } else {
      b & 0x3F
    }
  }
  if b0 >= 0xC2 && b0 <= 0xDF {
    let c1 = cont(pos + 1, 0x80, 0xBF)
    if c1 >= 0 {
      return (((b0 & 0x1F) << 6) | c1, 2)
    }
  } else if b0 >= 0xE0 && b0 <= 0xEF {
    // E0 excludes overlong forms, ED the surrogates.
    let (lo, hi) = match b0 {
      0xE0 => (0xA0, 0xBF)
      0xED => (0x80, 0x9F)
      _ => (0x80, 0xBF)
    }
    let c1 = cont(pos + 1, lo, hi)
    let c2 = if c1 >= 0 { cont(pos + 2, 0x80, 0xBF) } else { -1 }
    if c2 >= 0 {
      return (((b0 & 0x0F) << 12) | (c1 << 6) | c2, 3)
    }
  } else if b0 >= 0xF0 && b0 <= 0xF4 {
    // F0 excludes overlong forms, F4 code points past U+10FFFF.
    let (lo, hi) = match b0 {
      0xF0 => (0x90, 0xBF)
      0xF4 => (0x80, 0x8F)
      _ => (0x80, 0xBF)
    }
    let c1 = cont(pos + 1, lo, hi)
    let c2 = if c1 >= 0 { cont(pos + 2, 0x80, 0xBF) } else { -1 }
    let c3 = if c2 >= 0 { cont(pos + 3, 0x80, 0xBF) } else { -1 }
    if c3 >= 0 {
      return (((b0 & 0x07) << 18) | (c1 << 12) | (c2 << 6) | c3, 4)
    }
  }
  (-1, 1)
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
