///|
/// A seeded pseudo-random generator: xoshiro256** (Blackman and Vigna),
/// with its state filled from the seed by SplitMix64.
///
/// It uses only 64-bit integer arithmetic, so a seed gives the same
/// sequence on every target, native and Wasm alike, and in every release:
/// the sequence is part of what a seeded Fault replays. It is not suitable
/// for cryptography.
pub struct Generator {
  priv mut s0 : UInt64
  priv mut s1 : UInt64
  priv mut s2 : UInt64
  priv mut s3 : UInt64
}

///|
/// Creates a generator from `seed`. Any seed is fine, including 0.
pub fn Generator::Generator(seed : UInt64) -> Generator {
  let mut state = seed
  let next = () => {
    state = state + 0x9E3779B97F4A7C15UL
    let z = state
    let z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL
    let z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL
    z ^ (z >> 31)
  }
  let s0 = next()
  let s1 = next()
  let s2 = next()
  let s3 = next()
  { s0, s1, s2, s3, }
}

///|
/// The next 64-bit output.
pub fn Generator::uint64(self : Generator) -> UInt64 {
  let result = rotl(self.s1 * 5UL, 7) * 9UL
  let t = self.s1 << 17
  self.s2 = self.s2 ^ self.s0
  self.s3 = self.s3 ^ self.s1
  self.s1 = self.s1 ^ self.s2
  self.s0 = self.s0 ^ self.s3
  self.s2 = self.s2 ^ t
  self.s3 = rotl(self.s3, 45)
  result
}

///|
/// A number drawn uniformly from [0, 1): the top 53 bits of the next
/// output, scaled. Scaling by a power of two is exact, so it is the same on
/// every target.
pub fn Generator::double(self : Generator) -> Double {
  (self.uint64() >> 11).to_double() * 0x1.0p-53
}

///|
/// A new generator seeded with the next output of this one, which advances
/// it exactly once, however many numbers the new one is asked for.
pub fn Generator::split(self : Generator) -> Generator {
  Generator(self.uint64())
}

///|
fn rotl(x : UInt64, k : Int) -> UInt64 {
  (x << k) | (x >> (64 - k))
}
