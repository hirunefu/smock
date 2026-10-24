// Exact decimal numbers, for the arithmetic helpers. A number has at most
// 18 digits before the point and 18 after, and it is kept as those digits,
// one per element. Every operation works on the digits, as on paper, with
// integers only, so it gives the same result on every target.

///|
/// The most digits a number has before its point, and after it.
let max_places : Int32 = 18

///|
/// The digits a number keeps: 18 before the point and 18 after.
let decimal_width : Int32 = 36

///|
/// A decimal number: its sign and its digits, from 10^17 down to 10^-18.
/// Zero is never negative.
priv struct Decimal {
  negative : Bool
  digits : FixedArray[Int32]
}

///|
/// Why a number is not a `Decimal`.
priv suberror Beyond {
  /// It has more than 18 digits before the point.
  TooLarge
  /// It has more than 18 digits after the point.
  TooPrecise
}

///|
/// The number with the sign `negative` and the digits `digits`, zero made
/// positive.
fn Decimal::of(negative : Bool, digits : FixedArray[Int32]) -> Decimal {
  {
    negative: negative && !digits_all_zero(digits, 0, digits.length()),
    digits,
  }
}

///|
/// Whether `digits[from:to]` are all 0.
fn digits_all_zero(
  digits : FixedArray[Int32],
  from : Int32,
  to : Int32,
) -> Bool {
  for i in from..<to {
    if digits[i] != 0 {
      return false
    }
  }
  true
}

///|
/// The number that `text`, a JSON number, writes, such as `-1.50` or
/// `2.5e-3`. Leading and trailing zeros do not count against the bounds.
fn Decimal::parse(text : String) -> Decimal raise Beyond {
  let n = text.length()
  let mut i = 0
  let negative = n > 0 && text[0] == '-'
  if negative {
    i = 1
  }
  let int_start = i
  while i < n && is_ascii_digit_unit(text[i]) {
    i += 1
  }
  let int_end = i
  let mut fraction_start = i
  let mut fraction_end = i
  if i < n && text[i] == '.' {
    i += 1
    fraction_start = i
    while i < n && is_ascii_digit_unit(text[i]) {
      i += 1
    }
    fraction_end = i
  }
  // The exponent stops growing at 10^12. A text has fewer than 2^31
  // digits, so a digit that the exponent moves that far from the point is
  // beyond the bounds anyway, wherever it stands in the text.
  let mut exponent = 0L
  if i < n && (text[i] == 'e' || text[i] == 'E') {
    i += 1
    let exponent_negative = i < n && text[i] == '-'
    if i < n && (text[i] == '-' || text[i] == '+') {
      i += 1
    }
    while i < n && is_ascii_digit_unit(text[i]) {
      if exponent < 1_000_000_000_000L {
        exponent = exponent * 10L + (text[i] - '0').to_int64()
      }
      i += 1
    }
    if exponent_negative {
      exponent = -exponent
    }
  }
  // Each digit goes where its power of ten says, from the most significant
  // one down, so a number both too large and too precise is too large.
  let digits = FixedArray::make(decimal_width, 0)
  let mut power = (int_end - int_start).to_int64() - 1L + exponent
  for j in int_start..<int_end {
    decimal_place(digits, (text[j] - '0').to_int(), power)
    power -= 1L
  }
  for j in fraction_start..<fraction_end {
    decimal_place(digits, (text[j] - '0').to_int(), power)
    power -= 1L
  }
  Decimal::of(negative, digits)
}

///|
/// Whether the UTF-16 code unit `c` is an ASCII digit.
fn is_ascii_digit_unit(c : UInt16) -> Bool {
  c >= '0' && c <= '9'
}

///|
/// Puts `digit`, of the power of ten `power`, in `digits`. A digit that is
/// not 0 must fit.
fn decimal_place(
  digits : FixedArray[Int32],
  digit : Int32,
  power : Int64,
) -> Unit raise Beyond {
  if digit == 0 {
    return
  }
  if power >= max_places.to_int64() {
    raise TooLarge
  }
  if power < -max_places.to_int64() {
    raise TooPrecise
  }
  digits[max_places - 1 - power.to_int()] = digit
}

///|
/// The number as a plain decimal: no exponent, no leading zeros and no
/// trailing zeros after the point, such as `-2.5` or `0`.
fn Decimal::text(self : Decimal) -> String {
  let out = StringBuilder()
  self.write_whole(out)
  let mut last = decimal_width - 1
  while last >= max_places && self.digits[last] == 0 {
    last -= 1
  }
  if last >= max_places {
    out.write_char('.')
    for i in max_places..<=last {
      out.write_char(decimal_digit_char(self.digits[i]))
    }
  }
  out.to_string()
}

///|
/// Writes the sign and the digits before the point, `0` when there are
/// none.
fn Decimal::write_whole(self : Decimal, out : StringBuilder) -> Unit {
  if self.negative {
    out.write_char('-')
  }
  let mut first = 0
  while first < max_places && self.digits[first] == 0 {
    first += 1
  }
  if first == max_places {
    out.write_char('0')
  }
  for i in first..<max_places {
    out.write_char(decimal_digit_char(self.digits[i]))
  }
}

///|
/// The character of the decimal digit `d`.
fn decimal_digit_char(d : Int32) -> Char {
  ('0'.to_int() + d).unsafe_to_char()
}

///|
/// The number with the other sign.
fn Decimal::negated(self : Decimal) -> Decimal {
  Decimal::of(!self.negative, self.digits)
}

///|
/// `self + other`.
fn Decimal::add(self : Decimal, other : Decimal) -> Decimal raise Beyond {
  if self.negative == other.negative {
    return Decimal::of(self.negative, digits_sum(self.digits, other.digits))
  }
  // The signs differ: the larger magnitude less the smaller one, with the
  // larger one's sign.
  if digits_compare(self.digits, other.digits) >= 0 {
    Decimal::of(self.negative, digits_difference(self.digits, other.digits))
  } else {
    Decimal::of(other.negative, digits_difference(other.digits, self.digits))
  }
}

///|
/// Compares the magnitudes `a` and `b`, of the same length: -1, 0 or 1.
fn digits_compare(a : FixedArray[Int32], b : FixedArray[Int32]) -> Int32 {
  for i in 0..<a.length() {
    if a[i] != b[i] {
      return if a[i] < b[i] { -1 } else { 1 }
    }
  }
  0
}

///|
/// The magnitude `a + b`, of their length, `a` and `b` of the same length.
fn digits_sum(
  a : FixedArray[Int32],
  b : FixedArray[Int32],
) -> FixedArray[Int32] raise Beyond {
  let out = FixedArray::make(a.length(), 0)
  let mut carry = 0
  for i = a.length() - 1; i >= 0; i = i - 1 {
    let d = a[i] + b[i] + carry
    out[i] = d % 10
    carry = d / 10
  }
  if carry > 0 {
    raise TooLarge
  }
  out
}

///|
/// The magnitude `a - b`, `a` at least `b` and of the same length.
fn digits_difference(
  a : FixedArray[Int32],
  b : FixedArray[Int32],
) -> FixedArray[Int32] {
  let out = a.copy()
  digits_take_away(out, b)
  out
}

///|
/// Takes the magnitude `b` away from `a`, in place: `a` is at least `b`,
/// and of the same length.
fn digits_take_away(a : FixedArray[Int32], b : FixedArray[Int32]) -> Unit {
  let mut borrow = 0
  for i = a.length() - 1; i >= 0; i = i - 1 {
    let d = a[i] - b[i] - borrow
    if d < 0 {
      a[i] = d + 10
      borrow = 1
    } else {
      a[i] = d
      borrow = 0
    }
  }
}

///|
/// `self × other`, exact: a product with more than 18 digits after the
/// point is too precise, not rounded.
fn Decimal::multiply(self : Decimal, other : Decimal) -> Decimal raise Beyond {
  // The digits of the product, from 10^35 down to 10^-36: a digit of
  // `self` at `i` times one of `other` at `j` goes to `i + j + 1`.
  let product = FixedArray::make(2 * decimal_width, 0)
  for i in 0..<decimal_width {
    let a = self.digits[i]
    if a == 0 {
      continue
    }
    for j in 0..<decimal_width {
      product[i + j + 1] += a * other.digits[j]
    }
  }
  for k = 2 * decimal_width - 1; k > 0; k = k - 1 {
    product[k - 1] += product[k] / 10
    product[k] = product[k] % 10
  }
  // 10^17 is at 18, and 10^-18 at 53.
  if !digits_all_zero(product, 0, max_places) {
    raise TooLarge
  }
  if !digits_all_zero(product, max_places + decimal_width, 2 * decimal_width) {
    raise TooPrecise
  }
  let digits = FixedArray::make(decimal_width, 0)
  for i in 0..<decimal_width {
    digits[i] = product[max_places + i]
  }
  Decimal::of(self.negative != other.negative, digits)
}

///|
/// The decimal places of a quotient.
let quotient_places : Int32 = 10

///|
/// Whether the number is 0.
fn Decimal::is_zero(self : Decimal) -> Bool {
  digits_all_zero(self.digits, 0, decimal_width)
}

///|
/// `self ÷ other`, rounded half to even at 10 decimal places. `other` is
/// not 0.
fn Decimal::divide(self : Decimal, other : Decimal) -> Decimal raise Beyond {
  // The digits of `self` with 10 zeros after them, divided by those of
  // `other`: the last digit of the quotient is of 10^-10, and 10^17 is at
  // 18.
  let dividend = FixedArray::make(decimal_width + quotient_places, 0)
  for i in 0..<decimal_width {
    dividend[i] = self.digits[i]
  }
  let divisor = digits_widened(other.digits)
  let remainder = FixedArray::make(decimal_width + 1, 0)
  let quotient = long_division(dividend, divisor, remainder)
  // Half to even: up when the remainder is more than half the divisor, or
  // just half of it and the last digit is odd.
  let last = quotient.length() - 1
  let above_half = digits_compare(
    remainder,
    digits_difference(divisor, remainder),
  )
  if above_half > 0 || (above_half == 0 && quotient[last] % 2 == 1) {
    digits_increment(quotient, last)
  }
  if !digits_all_zero(quotient, 0, max_places) {
    raise TooLarge
  }
  let digits = FixedArray::make(decimal_width, 0)
  for i in 0..<(max_places + quotient_places) {
    digits[i] = quotient[max_places + i]
  }
  Decimal::of(self.negative != other.negative, digits)
}

///|
/// The magnitude `digits` with a 0 before it.
fn digits_widened(digits : FixedArray[Int32]) -> FixedArray[Int32] {
  let out = FixedArray::make(digits.length() + 1, 0)
  for i in 0..<digits.length() {
    out[i + 1] = digits[i]
  }
  out
}

///|
/// The quotient of the magnitudes `dividend ÷ divisor`, with as many digits
/// as `dividend`, found one digit at a time as on paper. `divisor` starts
/// with a 0 and is not 0. `remainder`, all 0 and as long as `divisor`, ends
/// up holding what is left over.
fn long_division(
  dividend : FixedArray[Int32],
  divisor : FixedArray[Int32],
  remainder : FixedArray[Int32],
) -> FixedArray[Int32] {
  let n = remainder.length()
  let quotient = FixedArray::make(dividend.length(), 0)
  for k in 0..<dividend.length() {
    // The next digit comes down: the remainder times 10, plus the digit.
    // The remainder is below the divisor, so its first digit is 0.
    for i in 1..<n {
      remainder[i - 1] = remainder[i]
    }
    remainder[n - 1] = dividend[k]
    let mut digit = 0
    while digits_compare(remainder, divisor) >= 0 {
      digits_take_away(remainder, divisor)
      digit += 1
    }
    quotient[k] = digit
  }
  quotient
}

///|
/// Adds 1 to the magnitude `digits` at the digit `at`, carrying.
fn digits_increment(
  digits : FixedArray[Int32],
  at : Int32,
) -> Unit raise Beyond {
  for i = at; i >= 0; i = i - 1 {
    if digits[i] < 9 {
      digits[i] += 1
      return
    }
    digits[i] = 0
  }
  raise TooLarge
}

///|
/// The remainder of `self ÷ other` truncated toward zero: it has the sign
/// of `self`, as JavaScript's `%`. `other` is not 0. Both have their last
/// digit at 10^-18, so the remainder is exact.
fn Decimal::modulo(self : Decimal, other : Decimal) -> Decimal {
  let remainder = FixedArray::make(decimal_width + 1, 0)
  ignore(long_division(self.digits, digits_widened(other.digits), remainder))
  let digits = FixedArray::make(decimal_width, 0)
  for i in 0..<decimal_width {
    digits[i] = remainder[i + 1]
  }
  Decimal::of(self.negative, digits)
}

///|
/// Which way a number goes when digits are dropped.
priv enum Rounding {
  /// Toward +∞.
  Ceiling
  /// Toward −∞.
  Floor
  /// To the nearer one, and half away from zero.
  HalfAwayFromZero
  /// Toward zero.
  TowardZero
}

///|
/// The number with `places` digits after the point, from 0 to 18, the
/// others dropped as `rounding` says.
fn Decimal::rounded(
  self : Decimal,
  places : Int32,
  rounding : Rounding,
) -> Decimal raise Beyond {
  // The last digit kept, of 10^-places.
  let last = max_places - 1 + places
  let digits = FixedArray::make(decimal_width, 0)
  for i in 0..<=last {
    digits[i] = self.digits[i]
  }
  let dropped = !digits_all_zero(self.digits, last + 1, decimal_width)
  let away_from_zero = match rounding {
    Ceiling => dropped && !self.negative
    Floor => dropped && self.negative
    HalfAwayFromZero => dropped && self.digits[last + 1] >= 5
    TowardZero => false
  }
  if away_from_zero {
    digits_increment(digits, last)
  }
  Decimal::of(self.negative, digits)
}

///|
/// The number written with exactly `places` digits after the point, from 0
/// to 18, such as `19.990`; the digits after those are 0.
fn Decimal::fixed(self : Decimal, places : Int32) -> String {
  let out = StringBuilder()
  self.write_whole(out)
  if places > 0 {
    out.write_char('.')
    for i in max_places..<(max_places + places) {
      out.write_char(decimal_digit_char(self.digits[i]))
    }
  }
  out.to_string()
}
