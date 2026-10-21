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
  }
}

///|
/// `text` padded with `pad` to `length` code points, at its start or at its
/// end, as the helper `name` inserted at `at` gives it: the pad is repeated
/// and cut to fit. A text that long already, or an empty pad, is
/// unchanged.
fn padded(
  text : String,
  length : Int,
  pad : String,
  at_start : Bool,
  name : String,
  at : String,
) -> String raise RenderError {
  let have = text.char_length()
  if length <= have || pad == "" {
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
    utf8_length(text).to_int64() +
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
