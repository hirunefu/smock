///|
/// The code point `decode` returns for a byte that is not part of a
/// well-formed UTF-8 sequence. No instruction consumes it.
let not_a_char : Int = -1

///|
/// Decodes the code point that starts at `pos`, returning it and its length
/// in bytes. A byte that does not start a well-formed UTF-8 sequence decodes
/// as `not_a_char` with length 1.
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
  (not_a_char, 1)
}
