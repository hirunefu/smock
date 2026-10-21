// The fake-data helpers. They draw from the helpers' generator in the
// order the template is rendered, with integer arithmetic only, so a seed
// gives the same output on every target.

///|
/// A number drawn uniformly from 0 to `count - 1`: rejection sampling, so
/// that every value is equally likely, as the pick among a Stub's
/// `responses` draws.
fn below(rand : @prng.Generator, count : UInt64) -> UInt64 {
  rand.below(count)
}

///|
/// An integer drawn uniformly from `min` to `max`, both included.
fn between(rand : @prng.Generator, min : Int64, max : Int64) -> Int64 {
  min +
  below(rand, (max - min).reinterpret_as_uint64() + 1UL).reinterpret_as_int64()
}

///|
let hex_digits : String = "0123456789abcdef"

///|
/// `n` lower-case hex digits of `u`, from its most significant end.
fn hex(u : UInt64, n : Int) -> String {
  let out = StringBuilder()
  for i in 0..<n {
    let nibble = ((u >> (60 - 4 * i)) & 0xFUL).to_int()
    out.write_char(hex_digits[nibble].unsafe_to_char())
  }
  out.to_string()
}

///|
/// One of `items`, each equally likely.
fn choose(rand : @prng.Generator, items : Array[String]) -> String {
  items[below(rand, items.length().to_uint64()).to_int()]
}

///|
/// What the fake-data helper `helper` gives, drawn from `rand`.
fn draw(helper : Helper, rand : @prng.Generator) -> Json {
  match helper {
    Uuid => {
      // Version 4 (random), variant 10xx.
      let high = (rand.uint64() & 0xFFFFFFFFFFFF0FFFUL) | 0x4000UL
      let low = (rand.uint64() & 0x3FFFFFFFFFFFFFFFUL) | 0x8000000000000000UL
      let h = hex(high, 16)
      let l = hex(low, 16)
      Json::string("\{h[0:8]}-\{h[8:12]}-\{h[12:16]}-\{l[0:4]}-\{l[4:16]}")
    }
    Int(min, max) => Json::number(between(rand, min, max).to_double())
    Decimal(min, max, places) => {
      let mut scale = 1L
      for _ in 0..<places {
        scale *= 10L
      }
      let steps = between(rand, min * scale, max * scale)
      let magnitude = if steps < 0L { -steps } else { steps }
      let sign = if steps < 0L { "-" } else { "" }
      let fraction = (magnitude % scale).to_string().pad_start(places, '0')
      let text = "\{sign}\{magnitude / scale}.\{fraction}"
      Json::number(steps.to_double() / scale.to_double(), repr=text)
    }
    Bool => Json::boolean(rand.uint64() >> 63 == 1UL)
    Pick(values) => values[below(rand, values.length().to_uint64()).to_int()]
    Hex(n) => {
      let out = StringBuilder()
      let mut left = n
      while left > 0 {
        let take = if left < 16 { left } else { 16 }
        out.write_string(hex(rand.uint64(), take))
        left -= take
      }
      Json::string(out.to_string())
    }
    Word => Json::string(choose(rand, words))
    Words(n) =>
      Json::string(Array::makei(n, _ => choose(rand, words)).join(" "))
    FirstName => Json::string(choose(rand, first_names))
    LastName => Json::string(choose(rand, last_names))
    Name => {
      let first = choose(rand, first_names)
      let last = choose(rand, last_names)
      Json::string("\{first} \{last}")
    }
    Email => {
      let first = choose(rand, first_names).to_lower()
      let last = choose(rand, last_names).to_lower()
      let nn = below(rand, 100UL).to_int().to_string().pad_start(2, '0')
      Json::string("\{first}.\{last}\{nn}@example.com")
    }
    // Not fake data: Context::eval handles them.
    Now(_) | NowMillis(_) | Number | Range | JsonText | Raw => Json::null()
  }
}
