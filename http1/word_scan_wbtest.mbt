// The word-at-a-time checks of the head scan against the byte-at-a-time
// checks they stand for.

///|
/// The bytes of `word`, least significant first, as the head scan reads
/// them from memory.
fn word_bytes(word : UInt64) -> Array[Byte] {
  Array::makei(8, i => ((word >> (8 * i)) & 0xff).to_byte())
}

///|
/// A word of the bytes `bytes`, the first the least significant.
fn word_of(bytes : Array[Byte]) -> UInt64 {
  let mut word : UInt64 = 0
  for i in 0..<8 {
    word = word | (bytes[i].to_uint64() << (8 * i))
  }
  word
}

///|
fn check_word(word : UInt64) -> String? {
  let bytes = word_bytes(word)
  let control = bytes.iter().any(b => b < b' ' || b == b'\x7f')
  let visible = bytes.iter().all(b => b > b' ' && b < b'\x7f')
  if has_control(word) != control || is_visible(word) != visible {
    Some(
      "\{word.to_string(radix=16)}: has_control \{has_control(word)}, is_visible \{is_visible(word)}",
    )
  } else {
    None
  }
}

///|
test "the word checks of the head scan agree with the byte checks, for every byte in every place and for random words" {
  let wrong = []
  // Every byte value in every place, among bytes that pass either check,
  // bytes that fail it and bytes on either side of each bound.
  let fillers : Array[Byte] = [
    b'a', b'~', b'!', b' ', b'\x1f', b'\x7f', b'\x80', b'\xff', b'\x00', b'\t',
  ]
  for filler in fillers {
    for place in 0..<8 {
      for value in 0..<256 {
        let bytes = Array::make(8, filler)
        bytes[place] = value.to_byte()
        if check_word(word_of(bytes)) is Some(error) && wrong.length() < 5 {
          wrong.push(error)
        }
      }
    }
  }
  let rand = @random.Rand::chacha8(seed=b"smock http1 word-at-a-time scans")
  let interesting : Array[Byte] = [
    b' ', b'!', b'\x1f', b'\x20', b'\x21', b'\x7e', b'\x7f', b'\x80', b'\xff', b'\x00',
    b'\t', b'\r',
  ]
  for _ in 0..<200000 {
    let bytes = Array::makei(8, _ => {
      if rand.int(limit=3) == 0 {
        interesting[rand.int(limit=interesting.length())]
      } else {
        rand.int(limit=256).to_byte()
      }
    })
    if check_word(word_of(bytes)) is Some(error) && wrong.length() < 5 {
      wrong.push(error)
    }
  }
  debug_inspect(wrong, content="[]")
}
