// SHA-256, which the definition set digest is built on. It is written in
// MoonBit, so it gives the same digest on every target. The expected values
// are the examples published with FIPS 180-2 (and NIST's CAVP), and
// padding-boundary lengths checked with Python's hashlib.

///|
/// The SHA-256 digest of `data`, in lower-case hex.
fn sha256_hex(data : Bytes) -> String {
  let out = StringBuilder()
  for byte in @definitions.sha256(data) {
    out.write_string(byte.to_int().to_string(radix=16).pad_start(2, '0'))
  }
  out.to_string()
}

///|
/// `n` bytes of `a`.
fn a_times(n : Int32) -> Bytes {
  Bytes::make(n, b'a')
}

///|
test "SHA-256 gives the published digests of the FIPS 180-2 examples" {
  inspect(
    [
      "\"\": \{sha256_hex(b"")}",
      "abc: \{sha256_hex(b"abc")}",
      "448 bits: \{sha256_hex(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")}",
      "896 bits: \{sha256_hex(b"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu")}",
      "a million a: \{sha256_hex(a_times(1_000_000))}",
    ].join("\n"),
    content=(
      #|"": e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
      #|abc: ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
      #|448 bits: 248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1
      #|896 bits: cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1
      #|a million a: cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0
    ),
  )
}

///|
test "SHA-256 pads every length around a block boundary right" {
  inspect(
    [55, 56, 63, 64, 65, 119, 120, 128]
    .map(n => "\{n}: \{sha256_hex(a_times(n))}")
    .join("\n"),
    content=(
      #|55: 9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318
      #|56: b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a
      #|63: 7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34
      #|64: ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb
      #|65: 635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0
      #|119: 31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb
      #|120: 2f3d335432c70b580af0e8e1b3674a7c020d683aa5f73aaaedfdc55af904c21c
      #|128: 6836cf13bac400e9105071cd6af47084dfacad4e5e302c94bfed24e013afb73e
    ),
  )
}
