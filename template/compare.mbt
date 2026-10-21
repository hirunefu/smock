// Comparing JSON values by what they mean rather than how they are written:
// numbers by their value, which `json` conditions, `find` and list filters
// share, and list sorts order by, and members with a value taken as text,
// as `find` and list filters compare them.

///|
/// Whether two parsed JSON numbers, `a` and `b`, have the same value.
///
/// The parser keeps a number's source text, `a_text` or `b_text`, when its
/// Double cannot hold it: an integer above 2^53, or a number beyond a
/// Double's range, which becomes an infinity. Two such numbers are compared
/// by their text, as exact decimals, so that two 64-bit IDs that differ in
/// their last digit differ. Any other pair is compared by their Doubles.
pub fn same_number(
  a : Double,
  a_text : String?,
  b : Double,
  b_text : String?,
) -> Bool {
  match (a_text, b_text) {
    (Some(a_text), Some(b_text)) =>
      canonical_number(a_text) == canonical_number(b_text)
    _ => a == b
  }
}

///|
/// How two parsed JSON numbers, `a` and `b`, order by their value:
/// negative when `a` is below `b`, positive when above, and 0 when
/// `same_number` finds them the same. Two numbers that kept their source
/// text, `a_text` and `b_text`, are ordered by it, as exact decimals, so
/// that two 64-bit IDs that differ in their last digit order exactly; only
/// two whose exponents both have more than 18 digits, far beyond a
/// Double's range, are ordered by their digits alone. Any other pair is
/// ordered by their Doubles.
pub fn compare_numbers(
  a : Double,
  a_text : String?,
  b : Double,
  b_text : String?,
) -> Int {
  match (a_text, b_text) {
    (Some(a_text), Some(b_text)) =>
      ExactNumber::parse(a_text).compare(ExactNumber::parse(b_text))
    _ => a.compare(b)
  }
}

///|
/// A JSON number as an exact decimal: its sign, its significant digits and
/// the power of ten of the first of them.
priv struct ExactNumber {
  /// -1, 0 or 1.
  sign : Int
  /// The significant digits, without leading or trailing zeros: none for
  /// zero.
  digits : String
  /// The power of ten of the first significant digit. An exponent of more
  /// than 18 digits counts as one of 4 * 10^18, with its sign, beyond what
  /// any shorter exponent and the length of a text give.
  power : Int64
}

///|
/// The number that `text`, a JSON number, writes.
fn ExactNumber::parse(text : String) -> ExactNumber {
  let negative = text.has_prefix("-")
  let digits = StringBuilder()
  let mut fraction_digits = 0
  let mut in_fraction = false
  let mut exponent = 0L
  let mut exponent_digits = 0
  let mut exponent_negative = false
  let mut in_exponent = false
  for c in text {
    match c {
      '-' if in_exponent => exponent_negative = true
      '-' | '+' => ()
      '.' => in_fraction = true
      'e' | 'E' => in_exponent = true
      _ if in_exponent =>
        // Leading zeros do not count.
        if exponent_digits > 0 || c != '0' {
          exponent_digits += 1
          if exponent_digits <= 18 {
            exponent = exponent * 10L + (c.to_int() - '0'.to_int()).to_int64()
          }
        }
      _ => {
        digits.write_char(c)
        if in_fraction {
          fraction_digits += 1
        }
      }
    }
  }
  let digits = digits.to_string()
  let mut start = 0
  while start < digits.length() && digits[start] == '0' {
    start += 1
  }
  if start == digits.length() {
    return { sign: 0, digits: "", power: 0L, }
  }
  let mut end = digits.length()
  while digits[end - 1] == '0' {
    end -= 1
  }
  if exponent_digits > 18 {
    exponent = 4_000_000_000_000_000_000L
  }
  if exponent_negative {
    exponent = -exponent
  }
  // The first significant digit stands `digits.length() - 1 - start`
  // places before the last digit written, whose power of ten is the
  // exponent less the number of fraction digits.
  let shift = digits.length() - 1 - start - fraction_digits
  let sign = if negative { -1 } else { 1 }
  {
    sign,
    digits: digits[start:end].to_owned(),
    power: exponent + shift.to_int64(),
  }
}

///|
/// How two exact numbers order: by sign, then by the power of ten of
/// their first digit, then digit by digit.
fn ExactNumber::compare(self : ExactNumber, other : ExactNumber) -> Int {
  if self.sign != other.sign || self.sign == 0 {
    return self.sign.compare(other.sign)
  }
  let magnitude = if self.power != other.power {
    self.power.compare(other.power)
  } else {
    let a = self.digits
    let b = other.digits
    let mut order = a.length().compare(b.length())
    for i in 0..<a.length().min(b.length()) {
      if a[i] != b[i] {
        order = a[i].compare(b[i])
        break
      }
    }
    order
  }
  self.sign * magnitude
}

///|
/// The JSON number `text` written so that two numbers whose exponents have
/// at most 18 digits have the same canonical text exactly when they have
/// the same value: `0`, or an optional `-`, the significant digits without
/// leading or trailing zeros, `e` and the power of ten of the last digit.
/// It takes time linear in the length of `text`, however large its
/// exponent.
fn canonical_number(text : String) -> String {
  let negative = text.has_prefix("-")
  let digits = StringBuilder()
  let mut fraction_digits = 0
  let mut in_fraction = false
  let exponent = StringBuilder()
  let mut exponent_negative = false
  let mut in_exponent = false
  for c in text {
    match c {
      '-' if in_exponent => exponent_negative = true
      '-' | '+' => ()
      '.' => in_fraction = true
      'e' | 'E' => in_exponent = true
      _ if in_exponent => exponent.write_char(c)
      _ => {
        digits.write_char(c)
        if in_fraction {
          fraction_digits += 1
        }
      }
    }
  }
  let digits = digits.to_string()
  let mut start = 0
  while start < digits.length() && digits[start] == '0' {
    start += 1
  }
  if start == digits.length() {
    return "0"
  }
  let mut end = digits.length()
  while digits[end - 1] == '0' {
    end -= 1
  }
  let significant = digits[start:end].to_owned()
  // The power of ten of the last significant digit is the exponent plus
  // `shift`, which the length of `text` bounds.
  let shift = digits.length() - end - fraction_digits
  let exponent = exponent.to_string()
  let mut first = 0
  while first < exponent.length() && exponent[first] == '0' {
    first += 1
  }
  let exponent = exponent[first:].to_owned()
  let sign = if negative { "-" } else { "" }
  // An Int64 holds any exponent of at most 18 digits plus the shift. A
  // longer one is kept as written, with the shift apart: such numbers are
  // equal only when written alike.
  if exponent.length() <= 18 {
    let mut power = 0L
    for c in exponent {
      power = power * 10L + (c.to_int() - '0'.to_int()).to_int64()
    }
    if exponent_negative {
      power = -power
    }
    "\{sign}\{significant}e\{power + shift.to_int64()}"
  } else {
    let exponent_sign = if exponent_negative { "-" } else { "" }
    "\{sign}\{significant}e\{exponent_sign}\{exponent}+\{shift}"
  }
}

///|
/// A value that members are compared with, as `find` and list filters
/// compare them: a text, such as a query parameter's value, and the JSON
/// number it is, if it is one, read once for every member compared with
/// it.
pub struct FilterValue {
  priv text : String
  priv number : Json?
}

///|
/// The value whose text is `text`.
pub fn FilterValue::FilterValue(text : String) -> FilterValue {
  { text, number: number_of(text), }
}

///|
/// Whether the member value `actual` meets the value: a string equal to
/// its text; a number, when the text is a JSON number of equal value,
/// compared as `json` conditions compare numbers (see `same_number`), so
/// `12.50` meets `12.5` and integers beyond 2^53 compare exactly; or
/// `true`, `false` or `null`, when the text is that word. An object or an
/// array never meets it.
pub fn FilterValue::matches(self : FilterValue, actual : Json) -> Bool {
  match actual {
    String(text) => text == self.text
    Number(n, repr~) =>
      self.number is Some(Number(m, repr=m_text)) &&
      same_number(n, repr, m, m_text)
    True => self.text == "true"
    False => self.text == "false"
    Null => self.text == "null"
    Object(_) | Array(_) => false
  }
}
