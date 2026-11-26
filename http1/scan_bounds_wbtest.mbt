// The head scan's two bounds, at and around their edges and up to the
// largest Int32, with numbers alone: no buffer is made.

///|
/// `n` in hexadecimal, with its sign before the `0x`.
fn signed_hex(n : Int32) -> String {
  let digits = n.to_string(radix=16)
  if digits.has_prefix("-") {
    "-0x\{digits[1:]}"
  } else {
    "0x\{digits}"
  }
}

///|
/// `shortcut_stop(start, end, size_limit)` as text, with the numbers in
/// hexadecimal.
fn stop_hex(start : Int32, end : Int32, size_limit : Int32) -> String {
  "from \{signed_hex(start)} to \{signed_hex(end)}, limit \{signed_hex(size_limit)}: \{signed_hex(shortcut_stop(start, end, size_limit))}"
}

///|
test "the head scan's shortcuts stop at the end of the bytes held or at the header size limit past the head's start, whichever comes first, without wrapping up to the largest Int32" {
  // Source: shortcut_stop's doc comment, which the maintainer's
  // twenty-fourth round of #275's answers asked for (#435): the bound is
  // the smaller of `end` and `start + size_limit`, for any `start` and
  // `end` that are not negative and any limit, and the sum is made only
  // when it is at most `end`, so it cannot pass the largest Int32.
  inspect(
    [
      // The bytes held reach past the limit: the limit past `start`.
      stop_hex(0, 10, 4),
      stop_hex(3, 10, 4),
      // The limit reaches past the bytes held: their end.
      stop_hex(3, 5, 4),
      stop_hex(3, 10, 8),
      // The bytes held after `start` are the limit: both are the same
      // position. With a limit one less, the limit past `start`; with one
      // more, `end` (above).
      stop_hex(3, 10, 7),
      stop_hex(3, 11, 8),
      stop_hex(3, 10, 6),
      // A head's first byte, the first call scan_head makes.
      stop_hex(0, 1, 1),
      // Positions and limits at the top of Int32. Where the bytes held are
      // fewer than the limit, `start + size_limit` would pass the largest
      // Int32, and the bound is `end`.
      stop_hex(0x7ffffff9, 0x7fffffff, 0x7fffffff),
      stop_hex(1, 0x7fffffff, 0x7fffffff),
      stop_hex(0x40000000, 0x7fffffff, 0x40000000),
      stop_hex(0x7fffffff, 0x7fffffff, 1),
      // Where the bytes held are the limit, the sum is the largest Int32.
      stop_hex(0, 0x7fffffff, 0x7fffffff),
      stop_hex(0x3fffffff, 0x7fffffff, 0x40000000),
      stop_hex(0x40000000, 0x7fffffff, 0x3fffffff),
      stop_hex(0x7ffffffe, 0x7fffffff, 1),
      // Where they are more, the sum is below it.
      stop_hex(0x40000000, 0x7fffffff, 0x3ffffffe),
      stop_hex(0x7ffffffd, 0x7fffffff, 1),
      stop_hex(0, 0x7fffffff, 0x40000000),
      // The largest limit with few bytes held.
      stop_hex(0, 0x10, 0x7fffffff),
      // Outside what scan_head passes: a limit of 0 or less gives a
      // position at or below `start`, and `start` past `end` gives the
      // smaller of the two all the same.
      stop_hex(5, 10, 0),
      stop_hex(5, 10, -3),
      stop_hex(0, 0x7fffffff, -0x80000000),
      stop_hex(0x7fffffff, 0x7fffffff, -0x80000000),
      stop_hex(10, 5, 4),
      stop_hex(10, 5, -6),
      stop_hex(0x7fffffff, 0, 1),
    ].join("\n"),
    content=(
      #|from 0x0 to 0xa, limit 0x4: 0x4
      #|from 0x3 to 0xa, limit 0x4: 0x7
      #|from 0x3 to 0x5, limit 0x4: 0x5
      #|from 0x3 to 0xa, limit 0x8: 0xa
      #|from 0x3 to 0xa, limit 0x7: 0xa
      #|from 0x3 to 0xb, limit 0x8: 0xb
      #|from 0x3 to 0xa, limit 0x6: 0x9
      #|from 0x0 to 0x1, limit 0x1: 0x1
      #|from 0x7ffffff9 to 0x7fffffff, limit 0x7fffffff: 0x7fffffff
      #|from 0x1 to 0x7fffffff, limit 0x7fffffff: 0x7fffffff
      #|from 0x40000000 to 0x7fffffff, limit 0x40000000: 0x7fffffff
      #|from 0x7fffffff to 0x7fffffff, limit 0x1: 0x7fffffff
      #|from 0x0 to 0x7fffffff, limit 0x7fffffff: 0x7fffffff
      #|from 0x3fffffff to 0x7fffffff, limit 0x40000000: 0x7fffffff
      #|from 0x40000000 to 0x7fffffff, limit 0x3fffffff: 0x7fffffff
      #|from 0x7ffffffe to 0x7fffffff, limit 0x1: 0x7fffffff
      #|from 0x40000000 to 0x7fffffff, limit 0x3ffffffe: 0x7ffffffe
      #|from 0x7ffffffd to 0x7fffffff, limit 0x1: 0x7ffffffe
      #|from 0x0 to 0x7fffffff, limit 0x40000000: 0x40000000
      #|from 0x0 to 0x10, limit 0x7fffffff: 0x10
      #|from 0x5 to 0xa, limit 0x0: 0x5
      #|from 0x5 to 0xa, limit -0x3: 0x2
      #|from 0x0 to 0x7fffffff, limit -0x80000000: -0x80000000
      #|from 0x7fffffff to 0x7fffffff, limit -0x80000000: -0x1
      #|from 0xa to 0x5, limit 0x4: 0x5
      #|from 0xa to 0x5, limit -0x6: 0x4
      #|from 0x7fffffff to 0x0, limit 0x1: 0x0
    ),
  )
}

///|
/// `word_fits(at, stop)` as text, with the numbers in hexadecimal.
fn fits_hex(at : Int32, stop : Int32) -> String {
  "at \{signed_hex(at)}, stop \{signed_hex(stop)}: \{word_fits(at, stop)}"
}

///|
test "a word fits before the shortcuts' bound only when eight bytes lie between, without wrapping up to the largest Int32" {
  // Source: word_fits's doc comment, which the maintainer's twenty-fourth
  // round of #275's answers asked for (#435): true when `at + 8` is at
  // most `stop` as integers, for any positions that are not negative, so
  // false for a position past `stop` or fewer than eight before it, at any
  // size. The positions in the last eight below 2^31 are where `at + 8`,
  // the test before #435, wraps past the largest Int32.
  inspect(
    [
      // Seven, eight and nine bytes between, from 0 and from elsewhere.
      fits_hex(0, 7),
      fits_hex(0, 8),
      fits_hex(0, 9),
      fits_hex(5, 12),
      fits_hex(5, 13),
      fits_hex(5, 14),
      // No byte between, and a position past the bound.
      fits_hex(13, 13),
      fits_hex(14, 13),
      fits_hex(0x7fffffff, 0),
      // At the top of Int32: eight bytes, the last ones below 2^31, fit.
      fits_hex(0x7ffffff7, 0x7fffffff),
      fits_hex(0, 0x7fffffff),
      // From 2^31 - 8 on, `at + 8` passes the largest Int32, and seven
      // bytes or fewer are left.
      fits_hex(0x7ffffff8, 0x7fffffff),
      fits_hex(0x7ffffffe, 0x7fffffff),
      fits_hex(0x7fffffff, 0x7fffffff),
      // Below the top, on either side of 8.
      fits_hex(0x7ffffff0, 0x7ffffff8),
      fits_hex(0x7ffffff1, 0x7ffffff8),
    ].join("\n"),
    content=(
      #|at 0x0, stop 0x7: false
      #|at 0x0, stop 0x8: true
      #|at 0x0, stop 0x9: true
      #|at 0x5, stop 0xc: false
      #|at 0x5, stop 0xd: true
      #|at 0x5, stop 0xe: true
      #|at 0xd, stop 0xd: false
      #|at 0xe, stop 0xd: false
      #|at 0x7fffffff, stop 0x0: false
      #|at 0x7ffffff7, stop 0x7fffffff: true
      #|at 0x0, stop 0x7fffffff: true
      #|at 0x7ffffff8, stop 0x7fffffff: false
      #|at 0x7ffffffe, stop 0x7fffffff: false
      #|at 0x7fffffff, stop 0x7fffffff: false
      #|at 0x7ffffff0, stop 0x7ffffff8: true
      #|at 0x7ffffff1, stop 0x7ffffff8: false
    ),
  )
}
