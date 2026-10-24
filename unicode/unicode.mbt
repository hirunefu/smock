// Unicode case mapping and White_Space, from the data of one pinned version
// of the Unicode Character Database (`version`, in data.mbt, which
// scripts/gen-unicode-data.py generates). The data is part of format
// version 1, so a template gives the same output on every machine, target
// and release. Case mapping is the simple one, one code point to one, with
// no locale and no SpecialCasing: `ß` has no upper case of one code point,
// so it stays `ß`.

///|
/// The simple upper-case mapping of `c`, or `c` itself when it has none.
pub fn upper(c : Char) -> Char {
  let code = c.to_int()
  // ASCII, most of what a template maps, needs no search.
  if code < 0x80 {
    return if code >= 'a' && code <= 'z' {
      (code - 32).unsafe_to_char()
    } else {
      c
    }
  }
  mapped(upper_runs, c)
}

///|
/// The simple lower-case mapping of `c`, or `c` itself when it has none.
pub fn lower(c : Char) -> Char {
  let code = c.to_int()
  // ASCII, most of what a template maps, needs no search.
  if code < 0x80 {
    return if code >= 'A' && code <= 'Z' {
      (code + 32).unsafe_to_char()
    } else {
      c
    }
  }
  mapped(lower_runs, c)
}

///|
/// Whether `c` has the property White_Space.
pub fn is_white_space(c : Char) -> Bool {
  let code = c.to_int()
  for bounds in white_space_ranges {
    if code < bounds.0 {
      return false
    }
    if code <= bounds.1 {
      return true
    }
  }
  false
}

///|
/// What `runs`, a mapping as data.mbt writes it, maps `c` to: `c` itself
/// when no run maps it.
fn mapped(runs : FixedArray[(Int32, Int32, Int32, Int32)], c : Char) -> Char {
  let code = c.to_int()
  // The number of runs that start at or before `code`; the last of them is
  // the only one that may map it.
  let mut low = 0
  let mut high = runs.length()
  while low < high {
    let middle = (low + high) / 2
    if runs[middle].0 <= code {
      low = middle + 1
    } else {
      high = middle
    }
  }
  if low == 0 {
    return c
  }
  let (first, last, step, delta) = runs[low - 1]
  if code <= last && (code - first) % step == 0 {
    (code + delta).unsafe_to_char()
  } else {
    c
  }
}
