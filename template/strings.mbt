// The string helpers. Lengths count Unicode code points, so an emoji or a
// Japanese character counts as one.

///|
/// A string helper.
priv enum StringHelper {
  /// `len(x)`: the length of a text or an array.
  Len
  /// `concat(a, b, …)`: texts joined.
  Concat
  /// `padStart(s, length, pad?)`: padded at the start.
  PadStart
  /// `padEnd(s, length, pad?)`: padded at the end.
  PadEnd
  /// `uppercase(s)`: each code point mapped to its simple upper case.
  Uppercase
  /// `lowercase(s)`: each code point mapped to its simple lower case.
  Lowercase
  /// `trim(s)`: without White_Space at either end.
  Trim
}

///|
/// The string helper that `site` calls, checked. `None` when it calls a
/// helper of another family.
fn string_helper(site : CallSite) -> Helper? raise Syntax {
  let helper : StringHelper = match site.name {
    "len" => {
      site.takes([TextOrArray], least=1, most=1)
      Len
    }
    "concat" => {
      site.takes([Text], least=2, most=100)
      Concat
    }
    "padStart" => {
      site.takes([Text, Integer, Text], least=2, most=3)
      PadStart
    }
    "padEnd" => {
      site.takes([Text, Integer, Text], least=2, most=3)
      PadEnd
    }
    "uppercase" => {
      site.takes([Text], least=1, most=1)
      Uppercase
    }
    "lowercase" => {
      site.takes([Text], least=1, most=1)
      Lowercase
    }
    "trim" => {
      site.takes([Text], least=1, most=1)
      Trim
    }
    _ => return None
  }
  Some(Strings(helper))
}

///|
/// What the string helper `helper` gives for the values of its arguments,
/// `values`, inserted at `at`.
fn string_value(
  helper : StringHelper,
  values : Array[Json],
  at : String,
) -> Json raise RenderError {
  match helper {
    Len =>
      match values[0] {
        Array(items) => Json::number(items.length().to_double())
        json =>
          match text_value(json) {
            Some(text) => Json::number(text.char_length().to_double())
            None =>
              raise RenderError(
                at~,
                message=argument_problem("len", 0, TextOrArray, json),
              )
          }
      }
    Concat => {
      let texts = []
      let mut bytes = 0L
      for k, json in values {
        let text = text_argument("concat", k, json, at)
        bytes += utf8_length(text).to_int64()
        texts.push(text)
      }
      check_result("concat", bytes, at)
      let out = StringBuilder()
      for text in texts {
        out.write_string(text)
      }
      Json::string(out.to_string())
    }
    PadStart | PadEnd => {
      let at_start = helper is PadStart
      let name = if at_start { "padStart" } else { "padEnd" }
      let text = text_argument(name, 0, values[0], at)
      let length = integer_argument(name, 1, values[1], at)
      let pad = if values.length() > 2 {
        text_argument(name, 2, values[2], at)
      } else {
        " "
      }
      Json::string(padded(text, length, pad, at_start, name, at))
    }
    Uppercase | Lowercase => {
      let to_upper = helper is Uppercase
      let name = if to_upper { "uppercase" } else { "lowercase" }
      let text = text_argument(name, 0, values[0], at)
      Json::string(case_mapped(text, to_upper, name, at))
    }
    Trim => Json::string(trimmed(text_argument("trim", 0, values[0], at), at))
  }
}

///|
/// `text` padded with `pad` to `length` code points, at its start or at its
/// end, as the helper `name` inserted at `at` gives it: the pad is repeated
/// and cut to fit. A text that long already, or an empty pad, is
/// unchanged. Either way, the result is bounded before it is built.
fn padded(
  text : String,
  length : Int,
  pad : String,
  at_start : Bool,
  name : String,
  at : String,
) -> String raise RenderError {
  let have = text.char_length()
  let text_bytes = utf8_length(text).to_int64()
  if length <= have || pad == "" {
    check_result(name, text_bytes, at)
    return text
  }
  // The pad is written `whole` times, then its first `rest` code points.
  let fill = length - have
  let pad_length = pad.char_length()
  let whole = fill / pad_length
  let rest = fill % pad_length
  let mut rest_bytes = 0
  let mut taken = 0
  for c in pad {
    if taken == rest {
      break
    }
    rest_bytes += char_utf8_length(c)
    taken += 1
  }
  check_result(
    name,
    text_bytes +
    whole.to_int64() * utf8_length(pad).to_int64() +
    rest_bytes.to_int64(),
    at,
  )
  let out = StringBuilder()
  if !at_start {
    out.write_string(text)
  }
  for _ in 0..<whole {
    out.write_string(pad)
  }
  taken = 0
  for c in pad {
    if taken == rest {
      break
    }
    out.write_char(c)
    taken += 1
  }
  if at_start {
    out.write_string(text)
  }
  out.to_string()
}

///|
/// `text` with each code point mapped to its simple upper case, or lower
/// case, as the helper `name` inserted at `at` gives it. A mapping may take
/// more or fewer bytes of UTF-8 than the code point it maps, so the result
/// is measured, and bounded, before it is built.
fn case_mapped(
  text : String,
  to_upper : Bool,
  name : String,
  at : String,
) -> String raise RenderError {
  let mut bytes = 0L
  for c in text {
    let mapped = if to_upper { @unicode.upper(c) } else { @unicode.lower(c) }
    bytes += char_utf8_length(mapped).to_int64()
  }
  check_result(name, bytes, at)
  let out = StringBuilder()
  for c in text {
    out.write_char(if to_upper { @unicode.upper(c) } else { @unicode.lower(c) })
  }
  out.to_string()
}

///|
/// `text` without the code points that have the property White_Space at
/// either end, as `trim` inserted at `at` gives it, bounded before it is
/// built.
fn trimmed(text : String, at : String) -> String raise RenderError {
  // In UTF-16 code units, where the first code point that is not
  // White_Space starts (-1 while there is none) and where the last one
  // ends; and, in bytes of UTF-8, the same places.
  let mut start = -1
  let mut end = 0
  let mut start_bytes = 0L
  let mut end_bytes = 0L
  let mut units = 0
  let mut bytes = 0L
  for c in text {
    let width = if c.to_int() > 0xFFFF { 2 } else { 1 }
    let utf8 = char_utf8_length(c).to_int64()
    if !@unicode.is_white_space(c) {
      if start < 0 {
        start = units
        start_bytes = bytes
      }
      end = units + width
      end_bytes = bytes + utf8
    }
    units += width
    bytes += utf8
  }
  if start < 0 {
    return ""
  }
  check_result("trim", end_bytes - start_bytes, at)
  if start == 0 && end == units {
    text
  } else {
    text[start:end].to_owned()
  }
}
