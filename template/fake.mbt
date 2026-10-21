// The fake-data helpers, `fake.*`. They take literals only, and draw from
// the helpers' generator in the order the template is rendered, with
// integer arithmetic only, so a seed gives the same output on every
// target.

///|
/// A fake-data helper, with the literal arguments it was checked to take.
priv enum FakeHelper {
  Uuid
  Int(Int64, Int64)
  FakeDecimal(Int64, Int64, Int)
  Bool
  Pick(Array[Json])
  Hex(Int)
  Word
  Words(Int)
  FirstName
  LastName
  Name
  Email
}

///|
/// The fake-data helper that `site` calls, checked: every argument is a
/// literal. `None` when it calls a helper of another family.
fn fake_helper(site : CallSite) -> Helper? raise Syntax {
  let helper : FakeHelper = match site.name {
    "fake.uuid" => {
      site.count(0)
      Uuid
    }
    "fake.int" => {
      site.count(2)
      let min = site.integer(0, -max_integer, max_integer)
      let max = site.integer(1, -max_integer, max_integer)
      site.ordered(min, max)
      Int(min, max)
    }
    "fake.decimal" => {
      site.count(3)
      let bound = 1_000_000_000L
      let min = site.integer(0, -bound, bound)
      let max = site.integer(1, -bound, bound)
      let places = site.integer(2, 1L, 6L).to_int()
      site.ordered(min, max)
      FakeDecimal(min, max, places)
    }
    "fake.bool" => {
      site.count(0)
      Bool
    }
    "fake.pick" => {
      if site.args.length() < 1 || site.args.length() > 100 {
        raise Syntax(
          site.start,
          "fake.pick() takes 1 to 100 literals, not \{site.args.length()}",
        )
      }
      Pick(
        site.args.map(arg => {
          match arg.1 {
            Literal(json) => json
            _ =>
              raise Syntax(
                arg.0,
                "fake.pick() takes literals: strings, numbers, true, false or null",
              )
          }
        }),
      )
    }
    "fake.hex" => {
      site.count(1)
      Hex(site.integer(0, 1L, 64L).to_int())
    }
    "fake.word" => {
      site.count(0)
      Word
    }
    "fake.words" => {
      site.count(1)
      Words(site.integer(0, 1L, 100L).to_int())
    }
    "fake.firstName" => {
      site.count(0)
      FirstName
    }
    "fake.lastName" => {
      site.count(0)
      LastName
    }
    "fake.name" => {
      site.count(0)
      Name
    }
    "fake.email" => {
      site.count(0)
      Email
    }
    _ => return None
  }
  Some(Fake(helper))
}

///|
/// Raises a problem when the minimum `min` exceeds the maximum `max`.
fn CallSite::ordered(
  self : CallSite,
  min : Int64,
  max : Int64,
) -> Unit raise Syntax {
  if min > max {
    raise Syntax(
      self.start,
      "\{self.name}(): the minimum \{min} exceeds the maximum \{max}",
    )
  }
}

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
fn draw(helper : FakeHelper, rand : @prng.Generator) -> Json {
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
    FakeDecimal(min, max, places) => {
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
  }
}
