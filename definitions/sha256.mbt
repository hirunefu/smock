// SHA-256 (FIPS 180-4), written in MoonBit so that the definition set
// digest needs no C and is the same on every target.

///|
/// The round constants: the first 32 bits of the fractional parts of the
/// cube roots of the first 64 primes.
let sha256_k : FixedArray[UInt32] = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
  0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
  0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
  0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
  0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
  0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
  0xc67178f2,
]

///|
/// The SHA-256 digest of `data`: 32 bytes.
pub fn sha256(data : BytesView) -> Bytes {
  let hasher = Sha256::new()
  hasher.update(data)
  hasher.finish()
}

///|
/// A SHA-256 computation fed in pieces: `finish` gives the digest of every
/// byte given to `update`, in order, as one message. So a large message can
/// be hashed a piece at a time, without first copying it into one.
priv struct Sha256 {
  /// The hash state: eight 32-bit words.
  state : FixedArray[UInt32]
  /// The message schedule, reused for each block.
  w : FixedArray[UInt32]
  /// The bytes of a block not yet complete, the first `pending` of them.
  block : FixedArray[Byte]
  mut pending : Int32
  /// How many bytes were given so far.
  mut length : UInt64
}

///|
/// Starts a SHA-256 computation with no bytes given.
fn Sha256::new() -> Sha256 {
  {
    state: [
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
      0x5be0cd19,
    ],
    w: FixedArray::make(64, 0),
    block: FixedArray::make(64, 0),
    pending: 0,
    length: 0,
  }
}

///|
/// Hashes `data` after the bytes given before.
fn Sha256::update(self : Sha256, data : BytesView) -> Unit {
  self.length += data.length().to_uint64()
  let mut offset = 0
  // First complete the block in progress, if there is one.
  if self.pending > 0 {
    while self.pending < 64 && offset < data.length() {
      self.block[self.pending] = data[offset]
      self.pending += 1
      offset += 1
    }
    if self.pending < 64 {
      return
    }
    compress(self.state, self.w, Bytes::from_array(self.block[:]), 0)
    self.pending = 0
  }
  // Then whole blocks straight from `data`, and keep the rest.
  while offset + 64 <= data.length() {
    compress(self.state, self.w, data, offset)
    offset += 64
  }
  while offset < data.length() {
    self.block[self.pending] = data[offset]
    self.pending += 1
    offset += 1
  }
}

///|
/// The digest of every byte given: 32 bytes. Hashes the padding: a 1 bit,
/// zeros, and the length in bits as a 64-bit big-endian number, which ends
/// the last block or two.
fn Sha256::finish(self : Sha256) -> Bytes {
  let bits = self.length * 8
  let zeros = if self.pending < 56 {
    55 - self.pending
  } else {
    119 - self.pending
  }
  self.update(
    Bytes::makei(1 + zeros + 8, i => {
      if i == 0 {
        b'\x80'
      } else if i <= zeros {
        b'\x00'
      } else {
        (bits >> (8 * (zeros + 8 - i))).to_byte()
      }
    }),
  )
  Bytes::makei(32, i => (self.state[i / 4] >> (24 - 8 * (i % 4))).to_byte())
}

///|
/// Processes the 64-byte block of `block` at `offset` into `state`, with
/// `w` as the message schedule.
fn compress(
  state : FixedArray[UInt32],
  w : FixedArray[UInt32],
  block : BytesView,
  offset : Int32,
) -> Unit {
  for i in 0..<16 {
    let at = offset + 4 * i
    w[i] = (block[at].to_uint() << 24) |
      (block[at + 1].to_uint() << 16) |
      (block[at + 2].to_uint() << 8) |
      block[at + 3].to_uint()
  }
  for i in 16..<64 {
    let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
    let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
    w[i] = w[i - 16] + s0 + w[i - 7] + s1
  }
  let mut a = state[0]
  let mut b = state[1]
  let mut c = state[2]
  let mut d = state[3]
  let mut e = state[4]
  let mut f = state[5]
  let mut g = state[6]
  let mut h = state[7]
  for i in 0..<64 {
    let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
    let ch = (e & f) ^ (e.lnot() & g)
    let t1 = h + s1 + ch + sha256_k[i] + w[i]
    let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
    let maj = (a & b) ^ (a & c) ^ (b & c)
    let t2 = s0 + maj
    h = g
    g = f
    f = e
    e = d + t1
    d = c
    c = b
    b = a
    a = t1 + t2
  }
  state[0] += a
  state[1] += b
  state[2] += c
  state[3] += d
  state[4] += e
  state[5] += f
  state[6] += g
  state[7] += h
}

///|
/// `x` rotated right by `n` bits, 0 < n < 32.
fn rotr(x : UInt32, n : Int32) -> UInt32 {
  (x >> n) | (x << (32 - n))
}
