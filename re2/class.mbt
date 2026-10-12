///|
/// The largest code point.
const MAX_CHAR : Int = 0x10FFFF

///|
/// A set of code points: sorted, non-overlapping, non-adjacent ranges stored
/// as `[lo0, hi0, lo1, hi1, ...]`, both ends included.
priv struct CharSet {
  ranges : FixedArray[Int]
}

///|
/// The set of the given inclusive ranges, in any order, possibly overlapping.
fn CharSet::of(ranges : Array[(Int, Int)]) -> CharSet {
  let sorted = ranges.copy()
  sorted.sort_by((a, b) => a.0.compare(b.0))
  let out : Array[Int] = []
  for r in sorted {
    let (lo, hi) = r
    let n = out.length()
    if n > 0 && lo <= out[n - 1] + 1 {
      if hi > out[n - 1] {
        out[n - 1] = hi
      }
    } else {
      out.push(lo)
      out.push(hi)
    }
  }
  { ranges: FixedArray::from_array(out), }
}

///|
/// Every code point not in `self`.
fn CharSet::negate(self : CharSet) -> CharSet {
  let out : Array[(Int, Int)] = []
  let mut next = 0
  let r = self.ranges
  for i = 0; i < r.length(); i = i + 2 {
    if r[i] > next {
      out.push((next, r[i] - 1))
    }
    next = r[i + 1] + 1
  }
  if next <= MAX_CHAR {
    out.push((next, MAX_CHAR))
  }
  CharSet::of(out)
}

///|
fn CharSet::contains(self : CharSet, c : Int) -> Bool {
  let r = self.ranges
  // Binary search for the last range whose start is <= c.
  let mut lo = 0
  let mut hi = r.length() / 2
  while lo < hi {
    let mid = (lo + hi) / 2
    if r[2 * mid] <= c {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  lo > 0 && c <= r[2 * (lo - 1) + 1]
}
