// White-box tests of how the decoders measure their text before they build
// it: `lossy_utf8_length` must count what `@utf8.decode_lossy` writes, a
// U+FFFD for each maximal subpart that is not UTF-8. They run on native and
// on wasm-gc.

///|
/// The bytes where UTF-8's rules change: ASCII, the ends of the ranges of
/// continuation bytes, every kind of lead byte, and bytes that never occur.
let boundary_bytes : Array[Byte] = [
  b'\x00', b'\x41', b'\x7F', b'\x80', b'\x8F', b'\x90', b'\x9F', b'\xA0', b'\xBF',
  b'\xC0', b'\xC1', b'\xC2', b'\xDF', b'\xE0', b'\xE1', b'\xEC', b'\xED', b'\xEE',
  b'\xEF', b'\xF0', b'\xF1', b'\xF3', b'\xF4', b'\xF5', b'\xFF',
]

///|
/// The sequences whose measure differs from the length of what
/// `@utf8.decode_lossy` writes, as hex, one per line.
fn mismatches(sequences : Array[Bytes]) -> String {
  let out = []
  for bytes in sequences {
    let measured = lossy_utf8_length(bytes)
    let written = utf8_length(@utf8.decode_lossy(bytes)).to_int64()
    if measured != written {
      let hex = bytes.iter().map(b => b.to_int().to_string(radix=16)).join(" ")
      out.push("\{hex}: measured \{measured}, written \{written}")
    }
  }
  out.join("\n")
}

///|
test "the measure of decoded bytes is the UTF-8 that decode_lossy writes: valid, truncated, overlong and surrogate sequences" {
  let cases : Array[Bytes] = [
    b"",
    b"abc",
    @utf8.encode("é日👍"),
    b"\xE6\x97",
    b"\xF0\x9F\x91",
    b"\xF0\x9F",
    b"\xC3",
    b"a\xE6\x97b",
    b"\xC0\x80",
    b"\xC1\xBF",
    b"\xE0\x80\x80",
    b"\xF0\x80\x80\x80",
    b"\xED\xA0\x80",
    b"\xED\xBF\xBF",
    b"\xF4\x90\x80\x80",
    b"\xF5\x80\x80\x80",
    b"\x80",
    b"\xBF\xBF",
    b"\xFE\xFF",
    b"\xE0\xA0\xE0\xA0\x80",
    b"\xF0\x90\x80a",
  ]
  inspect(
    cases.map(bytes => lossy_utf8_length(bytes).to_string()).join(" "),
    content="0 3 9 3 3 3 3 5 6 6 9 12 9 9 12 12 3 6 6 6 4",
  )
  inspect(mismatches(cases), content="")
}

///|
test "the measure of decoded bytes agrees with decode_lossy on every sequence of up to four boundary bytes" {
  let sequences : Array[Bytes] = []
  let n = boundary_bytes.length()
  for a in boundary_bytes {
    sequences.push(Bytes::from_array([a]))
    for b in boundary_bytes {
      sequences.push(Bytes::from_array([a, b]))
      for c in boundary_bytes {
        sequences.push(Bytes::from_array([a, b, c]))
        for d in boundary_bytes {
          sequences.push(Bytes::from_array([a, b, c, d]))
        }
      }
    }
  }
  assert_eq(sequences.length(), n + n * n + n * n * n + n * n * n * n)
  inspect(mismatches(sequences), content="")
}
