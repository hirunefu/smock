// Exact decimal numbers, for the bounds of sampled numbers. A bound has at
// most 18 digits before the point and 18 after. The sampler only adds or
// subtracts 1, halves a sum of two bounds and rounds to a whole number, so
// a number is kept as an integer count of 10^-19, one place more than a
// bound has, and halving a sum is exact. The arithmetic uses no float, so
// every target gives the same digits.

///|
/// The most digits a bound has before its point, and after it.
let max_places : Int = 18

///|
/// The places a number keeps after its point.
let places : Int = max_places + 1

///|
/// 10^19, the number 1 in units of 10^-19.
let one_unit : @bigint.BigInt = @bigint.BigInt::from_string(
  "1" + "0".repeat(places),
)

///|
/// An exact decimal number.
priv struct Decimal {
  /// The number times 10^19.
  units : @bigint.BigInt
}

///|
/// The number that `text`, a JSON number such as `-1.50` or `2.5e-3`,
/// writes, or `None` when it has more than 18 digits before the point or
/// after it, or is not a number. Leading and trailing zeros do not count.
fn Decimal::parse(text : String) -> Decimal? {
  let n = text.length()
  let mut i = 0
  let negative = n > 0 && text[0] == '-'
  if negative {
    i = 1
  }
  // The digits, without the point, and how many of them come after it.
  let digits = StringBuilder()
  let mut fraction = 0
  while i < n && is_digit(text[i]) {
    digits.write_char(text[i].unsafe_to_char())
    i += 1
  }
  if i < n && text[i] == '.' {
    i += 1
    while i < n && is_digit(text[i]) {
      digits.write_char(text[i].unsafe_to_char())
      fraction += 1
      i += 1
    }
  }
  // The exponent stops growing at 10^12: a digit that it moves that far
  // from the point is beyond the bounds anyway.
  let mut exponent = 0L
  if i < n && (text[i] == 'e' || text[i] == 'E') {
    i += 1
    let exponent_negative = i < n && text[i] == '-'
    if i < n && (text[i] == '-' || text[i] == '+') {
      i += 1
    }
    while i < n && is_digit(text[i]) {
      if exponent < 1_000_000_000_000L {
        exponent = exponent * 10L + (text[i] - '0').to_int64()
      }
      i += 1
    }
    if exponent_negative {
      exponent = -exponent
    }
  }
  if i < n || digits.is_empty() {
    return None
  }
  // The number is `digits` times 10^`last`: `last` is the power of ten of
  // the last digit.
  let digits = digits.to_string()
  let mut first = 0
  while first < digits.length() && digits[first] == '0' {
    first += 1
  }
  let mut end = digits.length()
  let mut last = exponent - fraction.to_int64()
  while end > first && digits[end - 1] == '0' {
    end -= 1
    last += 1L
  }
  if end == first {
    return Some({ units: 0N, })
  }
  let before = (end - first).to_int64() + last
  if before > max_places.to_int64() || -last > max_places.to_int64() {
    return None
  }
  let units = @bigint.BigInt::from_string(
    digits.view(start_offset=first, end_offset=end).to_owned() +
    "0".repeat(places + last.to_int()),
  )
  Some({ units: if negative { -units } else { units }, })
}

///|
/// Whether the UTF-16 code unit `c` is an ASCII digit.
fn is_digit(c : UInt16) -> Bool {
  c >= '0' && c <= '9'
}

///|
/// The number as a plain decimal: no exponent, no leading zeros and no
/// trailing zeros after the point, such as `-2.5` or `0`.
fn Decimal::text(self : Decimal) -> String {
  let negative = self.units < 0N
  let digits = (if negative { -self.units } else { self.units }).to_string()
  let digits = digits.pad_start(places + 1, '0')
  let point = digits.length() - places
  let mut end = digits.length()
  while end > point && digits[end - 1] == '0' {
    end -= 1
  }
  let out = StringBuilder()
  if negative {
    out.write_char('-')
  }
  out.write_string(digits.view(end_offset=point).to_owned())
  if end > point {
    out.write_char('.')
    out.write_string(digits.view(start_offset=point, end_offset=end).to_owned())
  }
  out.to_string()
}

///|
/// The number as JSON: its text, kept so that the file writes its exact
/// digits, and the nearest double.
fn Decimal::to_json(self : Decimal) -> Json {
  let text = self.text()
  // The text is a plain decimal, which always parses.
  let value = @string.parse_double(text) catch { _ => 0.0 }
  Json::number(value, repr=text)
}

///|
/// Compares two numbers.
fn Decimal::compare(self : Decimal, other : Decimal) -> Int {
  self.units.compare(other.units)
}

///|
/// Zero.
fn Decimal::zero() -> Decimal {
  { units: 0N, }
}

///|
/// The number plus `n`.
fn Decimal::plus(self : Decimal, n : Int) -> Decimal {
  { units: self.units + @bigint.BigInt::from_int(n) * one_unit, }
}

///|
/// The number halfway between `self` and `other`. The sum of two numbers
/// with at most 18 places is a whole count of 10^-18, so its half is exact
/// in units of 10^-19.
fn Decimal::middle(self : Decimal, other : Decimal) -> Decimal {
  { units: (self.units + other.units) / 2N, }
}

///|
/// What the number is above the whole number at or below it, in units of
/// 10^-19: from 0 up to, not including, 10^19.
fn Decimal::fraction_units(self : Decimal) -> @bigint.BigInt {
  let rest = self.units % one_unit
  if rest < 0N {
    rest + one_unit
  } else {
    rest
  }
}

///|
/// Whether the number is whole.
fn Decimal::is_whole(self : Decimal) -> Bool {
  self.fraction_units() == 0N
}

///|
/// The largest whole number at or below the number.
fn Decimal::floor(self : Decimal) -> Decimal {
  { units: self.units - self.fraction_units(), }
}

///|
/// The smallest whole number at or above the number.
fn Decimal::ceil(self : Decimal) -> Decimal {
  if self.is_whole() {
    self
  } else {
    self.floor().plus(1)
  }
}
