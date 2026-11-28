// How far the parser's buffer grows to hold the bytes fed to it, at and
// around 2^30 bytes and up to the largest Int32, with numbers alone: no
// buffer is made.

///|
/// `grown_capacity(capacity, needed)` as text, with the numbers in
/// hexadecimal.
fn grown_hex(capacity : Int32, needed : Int32) -> String {
  "0x\{capacity.to_string(radix=16)} for 0x\{needed.to_string(radix=16)}: 0x\{grown_capacity(capacity, needed).to_string(radix=16)}"
}

///|
test "the parser's buffer keeps its length while it holds the bytes, doubles below 2^30 bytes, and from 2^30 bytes grows to what it must hold" {
  // Source: grown_capacity's doc comment, which the maintainer's
  // twenty-second round of #275's answers asked for (#433): a buffer that
  // holds the bytes keeps its length; one below 2^30 bytes doubles until
  // it holds them; one of 2^30 bytes or more grows to the bytes needed.
  inspect(
    [
      // The bytes fit: the length stays, also at 2^30 and above.
      grown_hex(0x1000, 0),
      grown_hex(0x1000, 0x1000),
      grown_hex(0x40000000, 0x40000000),
      grown_hex(0x40000001, 0x1000),
      grown_hex(0x7fffffff, 0x7fffffff),
      // Below 2^30 bytes, the buffer doubles until the bytes fit.
      grown_hex(0x1000, 0x1001),
      grown_hex(0x1000, 0x2001),
      grown_hex(0x1000, 0x40000000),
      grown_hex(0x20000000, 0x20000001),
      // Just below 2^30, a buffer still doubles: twice 2^30 - 1 is
      // 2^31 - 2, which an Int32 holds.
      grown_hex(0x3fffffff, 0x40000000),
      // From 2^30 bytes on, the buffer grows to the bytes needed, up to the
      // largest Int32: doubling 2^30 would give 2^31, which an Int32 does
      // not hold.
      grown_hex(0x40000000, 0x40000001),
      grown_hex(0x40000000, 0x7fffffff),
      grown_hex(0x40000001, 0x40000002),
      grown_hex(0x7ffffffe, 0x7fffffff),
      // A buffer below 2^30 that must hold more than 2^30 bytes doubles up
      // to 2^30 or past it, then grows to the bytes needed.
      grown_hex(0x1000, 0x40000001),
      grown_hex(0x20000000, 0x7fffffff),
      grown_hex(0x3fffffff, 0x7fffffff),
    ].join("\n"),
    content=(
      #|0x1000 for 0x0: 0x1000
      #|0x1000 for 0x1000: 0x1000
      #|0x40000000 for 0x40000000: 0x40000000
      #|0x40000001 for 0x1000: 0x40000001
      #|0x7fffffff for 0x7fffffff: 0x7fffffff
      #|0x1000 for 0x1001: 0x2000
      #|0x1000 for 0x2001: 0x4000
      #|0x1000 for 0x40000000: 0x40000000
      #|0x20000000 for 0x20000001: 0x40000000
      #|0x3fffffff for 0x40000000: 0x7ffffffe
      #|0x40000000 for 0x40000001: 0x40000001
      #|0x40000000 for 0x7fffffff: 0x7fffffff
      #|0x40000001 for 0x40000002: 0x40000002
      #|0x7ffffffe for 0x7fffffff: 0x7fffffff
      #|0x1000 for 0x40000001: 0x40000001
      #|0x20000000 for 0x7fffffff: 0x7fffffff
      #|0x3fffffff for 0x7fffffff: 0x7fffffff
    ),
  )
}

///|
test "the parser's buffer always grows to hold the bytes, without wrapping, for every length a parser's buffer has and every need up to the largest Int32" {
  // Source: grown_capacity's doc comment: the length returned holds the
  // bytes needed and is never more than an Int32 holds, for any need up to
  // the largest Int32. That each call returns is what the test's end
  // shows. The lengths a parser's buffer has: 4,096 bytes doubled up to
  // 2^30 times, then lengths above 2^30; with others around 2^30 and the
  // smallest.
  let capacities = (0).until(18, inclusive=true).map(k => 4096 << k).collect()
  capacities.append([
    1, 3, 0x1fffffff, 0x20000001, 0x3fffffff, 0x40000001, 0x60000000, 0x7ffffffe,
    0x7fffffff,
  ])
  // Each power of two, one less and one more, and the largest Int32.
  let needs = [0, 1, 0x7fffffff]
  for k in 1..<31 {
    needs.append([(1 << k) - 1, 1 << k, (1 << k) + 1])
  }
  let wrong = []
  for capacity in capacities {
    for needed in needs {
      let grown = grown_capacity(capacity, needed)
      if (grown < needed || grown < capacity) && wrong.length() < 5 {
        wrong.push((capacity, needed, grown))
      }
    }
  }
  debug_inspect(wrong, content="[]")
}
