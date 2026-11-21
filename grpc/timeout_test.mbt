// gRPC's `grpc-timeout` through the module's public interface: 1 to 8
// digits, then the unit, `H` hours, `M` minutes, `S` seconds, `m`
// milliseconds, `u` microseconds or `n` nanoseconds
// (https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md), read
// as nanoseconds, saturated.

///|
/// What `value`, a `grpc-timeout` value, gives: its nanoseconds, or
/// `malformed`.
fn read(value : String) -> String {
  match @grpc.timeout_ns(value) {
    Some(nanoseconds) => nanoseconds.to_string()
    None => "malformed"
  }
}

///|
test "a timeout is 1 to 8 digits and a unit, read as nanoseconds" {
  let values = [
    "1H", "1M", "1S", "1m", "1u", "1n", "250m", "00000007S", "12345678u",
  ]
  inspect(
    values.map(value => "\{value}: \{read(value)}").join("\n"),
    content=(
      #|1H: 3600000000000
      #|1M: 60000000000
      #|1S: 1000000000
      #|1m: 1000000
      #|1u: 1000
      #|1n: 1
      #|250m: 250000000
      #|00000007S: 7000000000
      #|12345678u: 12345678000
    ),
  )
}

///|
test "eight digits of every unit are read without wrapping, and eight digits of hours saturate" {
  // grpc/README.mbt.md, Timeouts: "Eight digits of hours are more
  // nanoseconds than an `Int64` holds, so they saturate at
  // `0x7FFF_FFFF_FFFF_FFFF` rather than wrap." The maintainer confirmed
  // that value on 2026-11-21 (#327).
  // The limit, and just past it, as the maintainer decided on 2026-11-21
  // (#327): an hour is 3,600,000,000,000 ns (PROTOCOL-HTTP2's Hour, `H`),
  // and 2^63 - 1 ns is 2,562,047 hours and a part of one. So 2562047H,
  // 9,223,369,200,000,000,000 ns, is read exactly, and 2562048H,
  // 9,223,372,800,000,000,000 ns, is the fewest hours that pass what an
  // `Int64` holds, and saturates. No other unit reaches the limit: eight
  // digits of minutes, the next unit, are 5,999,999,940,000,000,000 ns.
  let values = [
    "99999999H", "99999999M", "99999999S", "99999999m", "99999999u", "99999999n",
    "2562047H", "2562048H",
  ]
  inspect(
    values.map(value => "\{value}: \{read(value)}").join("\n"),
    content=(
      #|99999999H: 9223372036854775807
      #|99999999M: 5999999940000000000
      #|99999999S: 99999999000000000
      #|99999999m: 99999999000000
      #|99999999u: 99999999000
      #|99999999n: 99999999
      #|2562047H: 9223369200000000000
      #|2562048H: 9223372036854775807
    ),
  )
}

///|
test "a timeout of 0, in any unit, is read" {
  for value in ["0m", "0H", "0n", "00000000S"] {
    inspect(read(value), content="0")
  }
}

///|
test "anything but 1 to 8 digits and one of H M S m u n is malformed" {
  let values = [
    "", "1", "m", "1x", "1h", "1s", "1ms", "123456789m", "-1m", "+1m", " 1m", "1m ",
    "1.5S", "1 m", "１m", "1M1",
  ]
  for value in values {
    guard read(value) == "malformed" else {
      fail("\{value} is read as \{read(value)}")
    }
  }
}

///|
/// What `value`, a `grpc-timeout` value, gives in milliseconds, or
/// `malformed`.
fn read_ms(value : String) -> String {
  match @grpc.timeout_ms(value) {
    Some(milliseconds) => milliseconds.to_string()
    None => "malformed"
  }
}

///|
test "a timeout in milliseconds is rounded up, so that a timeout above 0 is never 0 ms" {
  // grpc/README.mbt.md, Timeouts: "`@grpc.timeout_ms(value)` gives the same
  // timeout in whole milliseconds, rounded up, so that a timeout above 0 is
  // never 0 ms." The maintainer confirmed that rounding on 2026-11-21
  // (#327): `1n` is 1 ms.
  let values = [
    "250m", "5S", "1M", "1H", "1n", "1u", "999999n", "1000000n", "1000001n", "1500u",
    "0m", "0n", "0H",
  ]
  inspect(
    values.map(value => "\{value}: \{read_ms(value)}").join("\n"),
    content=(
      #|250m: 250
      #|5S: 5000
      #|1M: 60000
      #|1H: 3600000
      #|1n: 1
      #|1u: 1
      #|999999n: 1
      #|1000000n: 1
      #|1000001n: 2
      #|1500u: 2
      #|0m: 0
      #|0n: 0
      #|0H: 0
    ),
  )
}

///|
test "eight digits of every unit convert to milliseconds without wrapping, and eight digits of hours from their saturated nanoseconds" {
  // Eight digits of hours give 0x7FFF_FFFF_FFFF_FFFF ns rounded up to whole
  // milliseconds, 9,223,372,036,855 ms (grpc/README.mbt.md, Timeouts). The
  // maintainer confirmed both that value and the rounding up on 2026-11-21
  // (#327).
  // At the limit, 2562047H is 2,562,047 times the 3,600,000 ms of an hour,
  // 9,223,369,200,000 ms, a whole number of them; just past it, 2562048H
  // converts from the saturated nanoseconds, as eight digits of hours do
  // (the maintainer's decision of 2026-11-21, #327).
  let values = [
    "99999999H", "99999999M", "99999999S", "99999999m", "99999999u", "99999999n",
    "2562047H", "2562048H",
  ]
  inspect(
    values.map(value => "\{value}: \{read_ms(value)}").join("\n"),
    content=(
      #|99999999H: 9223372036855
      #|99999999M: 5999999940000
      #|99999999S: 99999999000
      #|99999999m: 99999999
      #|99999999u: 100000
      #|99999999n: 100
      #|2562047H: 9223369200000
      #|2562048H: 9223372036855
    ),
  )
}

///|
test "a malformed timeout has no milliseconds" {
  for value in ["", "1", "1x", "1ms", "123456789m", "-1m", "1.5S"] {
    guard read_ms(value) == "malformed" else {
      fail("\{value} is read as \{read_ms(value)}")
    }
  }
}

///|
/// The seed of the property that a `grpc-timeout` written as PROTOCOL-HTTP2
/// defines it reads as its digits times its unit, and that every other
/// value is malformed. The tests run with it on every push, in mutation runs
/// and in kill confirmations, so a failure reproduces. Each week,
/// `scripts/random-seeds.py` writes a random seed here in a working copy and
/// prints it (CONTRIBUTING.md, "Seeds").
const TIMEOUT_SEED : UInt64 = 13765748678475182504

///|
/// PROTOCOL-HTTP2's TimeoutUnit, each unit with its length in nanoseconds:
/// `H` Hour, `M` Minute, `S` Second, `m` Millisecond, `u` Microsecond and
/// `n` Nanosecond.
let timeout_units : Array[(Char, Int64)] = [
  ('H', 3_600_000_000_000L),
  ('M', 60_000_000_000L),
  ('S', 1_000_000_000L),
  ('m', 1_000_000L),
  ('u', 1_000L),
  ('n', 1L),
]

///|
/// Characters that are no TimeoutUnit, beside those that are: units in the
/// other case, other letters, the micro sign, a percent sign and a space.
let other_units : Array[Char] = ['h', 's', 'N', 'U', 'x', 'µ', '%', ' ']

///|
/// The largest number an `Int64` holds, 2^63 - 1.
let int64_max : @bigint.BigInt = @bigint.BigInt::from_int64(
  0x7FFF_FFFF_FFFF_FFFFL,
)

///|
/// The most hours whose nanoseconds an `Int64` holds: (2^63 - 1) divided by
/// the nanoseconds of an hour, 2,562,047. Of the six units, only hours have
/// values of eight digits or fewer whose nanoseconds pass what an `Int64`
/// holds.
let edge_hours : Int64 = {
  let hour = @bigint.BigInt::from_int64(3_600_000_000_000L)
  (int64_max / hour).to_int64()
}

///|
/// The longest delay the gRPC guide names, 2^31 - 1 ms
/// (docs/grpc/state-and-faults.md, "Deadlines"): a timeout whose
/// nanoseconds pass what an `Int64` holds is at least this long.
const LONGEST_DELAY_MS : Int64 = 2_147_483_647L

///|
/// A `grpc-timeout` value as the property's writer wrote it: its digits,
/// then its unit. The writer follows PROTOCOL-HTTP2's Timeout, `TimeoutValue
/// TimeoutUnit`, where TimeoutValue is a "positive integer as ASCII string
/// of at most 8 digits" and TimeoutUnit one of `timeout_units`, or breaks it
/// on purpose, with no digits, nine digits or another unit. Its digits may
/// also be all zeros: smock's guide reads a timeout of 0 in any unit
/// (docs/grpc/unmatched-and-refused-calls.md, "Timeouts").
#derive(Debug)
priv struct Written {
  digits : String
  unit : Char
}

///|
/// The value, as a client sends it.
fn Written::value(self : Written) -> String {
  "\{self.digits}\{self.unit}"
}

///|
/// The unit's length in nanoseconds, or `None` when it is no TimeoutUnit.
fn Written::unit_length(self : Written) -> Int64? {
  for unit in timeout_units {
    if unit.0 == self.unit {
      return Some(unit.1)
    }
  }
  None
}

///|
/// Whether PROTOCOL-HTTP2's Timeout holds the value: 1 to 8 digits, then a
/// TimeoutUnit.
fn Written::well_formed(self : Written) -> Bool {
  self.digits.length() >= 1 &&
  self.digits.length() <= 8 &&
  self.unit_length() is Some(_)
}

///|
/// The value's digits times its unit's nanoseconds, computed exactly.
fn Written::product(self : Written) -> @bigint.BigInt? {
  guard self.well_formed() && self.unit_length() is Some(unit) else {
    return None
  }
  Some(
    @bigint.BigInt::from_string(self.digits) * @bigint.BigInt::from_int64(unit),
  )
}

///|
/// The index of a random one of `n` choices.
fn pick(state : @quickcheck.RandomState, n : Int32) -> Int32 {
  state.next_uint(limit=n.reinterpret_as_uint()).reinterpret_as_int()
}

///|
/// `count` random ASCII digits.
fn random_digits(state : @quickcheck.RandomState, count : Int32) -> String {
  let out = StringBuilder()
  for _ in 0..<count {
    out.write_char(('0'.to_int() + pick(state, 10)).unsafe_to_char())
  }
  out.to_string()
}

///|
/// The writer: most values are well formed, with 1 to 8 random digits and
/// any unit; some are hours within 3 of `edge_hours`, in seven digits or
/// eight with a leading zero, where the nanoseconds pass what an `Int64`
/// holds; the rest have no digits, nine digits, or another unit.
impl @quickcheck.Arbitrary for Written with fn arbitrary(_size, state) {
  let unit = timeout_units[pick(state, timeout_units.length())].0
  match pick(state, 11) {
    0..<=5 => { digits: random_digits(state, 1 + pick(state, 8)), unit, }
    6 | 7 => {
      let hours = (edge_hours + (pick(state, 7) - 3).to_int64()).to_string()
      {
        digits: if pick(state, 2) == 0 {
          hours
        } else {
          "0\{hours}"
        },
        unit: 'H',
      }
    }
    8 => { digits: "", unit, }
    9 => { digits: random_digits(state, 9), unit, }
    _ =>
      {
        digits: random_digits(state, 1 + pick(state, 8)),
        unit: other_units[pick(state, other_units.length())],
      }
  }
}

///|
/// Where a unit stands among those the writer uses: the TimeoutUnits first,
/// in their order, then the others.
fn unit_rank(unit : Char) -> Int32 {
  for i, known in timeout_units {
    if known.0 == unit {
      return i
    }
  }
  for i, other in other_units {
    if other == unit {
      return timeout_units.length() + i
    }
  }
  timeout_units.length() + other_units.length()
}

///|
/// Smaller values: each without one of its digits, each with a digit that
/// is not `0` made `0`, and with a unit that stands earlier. Each has fewer
/// digits, smaller ones, or an earlier unit, so shrinking ends.
impl @quickcheck.Shrink for Written with fn shrink(self) {
  let out : Array[Written] = []
  let digits = self.digits
  for i in 0..<digits.length() {
    out.push({
      ..self,
      digits: digits[:i].to_owned() + digits[i + 1:].to_owned(),
    })
  }
  for i in 0..<digits.length() {
    if digits[i] != '0' {
      out.push({
        ..self,
        digits: digits[:i].to_owned() + "0" + digits[i + 1:].to_owned(),
      })
    }
  }
  let rank = unit_rank(self.unit)
  for known in timeout_units {
    if unit_rank(known.0) < rank {
      out.push({ ..self, unit: known.0, })
    }
  }
  out.iter()
}

///|
/// The property: a well-formed value reads as its digits times its unit,
/// exactly, in nanoseconds, and within a millisecond of it in whole
/// milliseconds, exactly when it is a whole number of them; when the
/// product passes what an `Int64` holds, the timeout is at least the
/// longest delay the gRPC guide names, 2^31 - 1 ms. Any other value is
/// malformed, in both readings.
fn Written::holds(self : Written) -> Bool {
  let value = self.value()
  let nanoseconds = @grpc.timeout_ns(value)
  let milliseconds = @grpc.timeout_ms(value)
  guard self.product() is Some(product) else {
    return nanoseconds is None && milliseconds is None
  }
  guard nanoseconds is Some(nanoseconds) && milliseconds is Some(milliseconds) else {
    return false
  }
  if product > int64_max {
    return nanoseconds >= LONGEST_DELAY_MS * 1_000_000L &&
      milliseconds >= LONGEST_DELAY_MS
  }
  let exact = product.to_int64()
  let whole = exact / 1_000_000L
  nanoseconds == exact &&
  (
    milliseconds == whole ||
    (exact % 1_000_000L != 0L && milliseconds == whole + 1L)
  )
}

///|
/// A failing value as it reads: the value, what each reading gives, and
/// what PROTOCOL-HTTP2's Timeout makes of it.
fn Written::describe(self : Written) -> String {
  let value = self.value()
  let expected = match self.product() {
    Some(product) => "\{product} ns"
    None => "malformed"
  }
  let nanoseconds = @debug.to_string(@grpc.timeout_ns(value))
  let milliseconds = @debug.to_string(@grpc.timeout_ms(value))
  "value \{@debug.to_string(value)}: timeout_ns \{nanoseconds}, timeout_ms \{milliseconds}, PROTOCOL-HTTP2 \{expected}"
}

///|
test "a grpc-timeout written as PROTOCOL-HTTP2 defines it reads as its digits times its unit, and every other value is malformed" {
  @quickcheck.check(
    (written : Written) => written.holds(),
    observe=written => {
      let product = written.product()
      [
        @quickcheck.classify(written.well_formed(), "well formed"),
        @quickcheck.classify(
          product is Some(product) && product > int64_max,
          "the nanoseconds pass what an Int64 holds",
        ),
        @quickcheck.classify(
          written.unit == 'H' &&
          written.well_formed() &&
          @bigint.BigInt::from_string(written.digits) ==
          @bigint.BigInt::from_int64(edge_hours),
          "exactly the most hours an Int64 holds",
        ),
        @quickcheck.classify(
          product is Some(product) && product.is_zero(),
          "a timeout of 0",
        ),
        @quickcheck.classify(
          written.well_formed() && written.digits.length() == 8,
          "eight digits",
        ),
        @quickcheck.classify(
          written.well_formed() &&
          written.digits.length() > 1 &&
          written.digits[0] == '0',
          "a leading zero",
        ),
        @quickcheck.classify(written.digits.length() == 0, "no digits"),
        @quickcheck.classify(written.digits.length() == 9, "nine digits"),
        @quickcheck.classify(written.unit_length() is None, "another unit"),
      ]
    },
    counterexample_context=Written::describe,
    count=2000,
    max_shrinks=1000,
    seed=TIMEOUT_SEED,
  )
}
