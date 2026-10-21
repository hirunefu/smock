// Comparing JSON values by what they mean rather than how they are written:
// numbers by their value, which `json` conditions, `find` and list filters
// share, and members with a value taken as text, as `find` and list
// filters compare them.

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
