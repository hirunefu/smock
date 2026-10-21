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
  /// `substr(s, from, length?)`: the code points from a position.
  Substr
  /// `indexOf(s, search, from?)`: where a text first occurs, or -1.
  IndexOf
  /// `includes(s, search)`: whether a text occurs.
  Includes
  /// `replace(s, search, replacement)`: the first occurrence replaced.
  Replace
  /// `replaceAll(s, search, replacement)`: every occurrence replaced.
  ReplaceAll
  /// `split(s, separator)`: an array of the texts between separators.
  Split
  /// `join(array, separator)`: the elements of an array as one text.
  Join
  /// `uppercase(s)`: each code point mapped to its simple upper case.
  Uppercase
  /// `lowercase(s)`: each code point mapped to its simple lower case.
  Lowercase
  /// `trim(s)`: without White_Space at either end.
  Trim
}

///|
/// The helper's name, for messages.
fn StringHelper::name(self : StringHelper) -> String {
  match self {
    Len => "len"
    Concat => "concat"
    PadStart => "padStart"
    PadEnd => "padEnd"
    Substr => "substr"
    IndexOf => "indexOf"
    Includes => "includes"
    Replace => "replace"
    ReplaceAll => "replaceAll"
    Split => "split"
    Join => "join"
    Uppercase => "uppercase"
    Lowercase => "lowercase"
    Trim => "trim"
  }
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
    "substr" => {
      site.takes([Text, Integer, Integer], least=2, most=3)
      Substr
    }
    "indexOf" => {
      site.takes([Text, Text, Integer], least=2, most=3)
      IndexOf
    }
    "includes" => {
      site.takes([Text], least=2, most=2)
      Includes
    }
    "replace" => {
      site.takes([Text], least=3, most=3)
      Replace
    }
    "replaceAll" => {
      site.takes([Text], least=3, most=3)
      ReplaceAll
    }
    "split" => {
      site.takes([Text], least=2, most=2)
      Split
    }
    "join" => {
      site.takes([Array, Text], least=2, most=2)
      Join
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
  let name = helper.name()
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
                message=argument_problem(name, 0, TextOrArray, json),
              )
          }
      }
    Concat => {
      let texts = []
      let mut bytes = 0L
      for k, json in values {
        let text = text_argument(name, k, json, at)
        bytes += utf8_length(text).to_int64()
        texts.push(text)
      }
      check_result(name, bytes, at)
      let out = StringBuilder()
      for text in texts {
        out.write_string(text)
      }
      Json::string(out.to_string())
    }
    PadStart | PadEnd => {
      let at_start = helper is PadStart
      let text = text_argument(name, 0, values[0], at)
      let length = integer_argument(name, 1, values[1], at)
      let pad = if values.length() > 2 {
        text_argument(name, 2, values[2], at)
      } else {
        " "
      }
      Json::string(padded(text, length, pad, at_start, name, at))
    }
    Substr => {
      let text = text_argument(name, 0, values[0], at)
      let from = integer_argument(name, 1, values[1], at)
      let length = if values.length() > 2 {
        Some(integer_argument(name, 2, values[2], at))
      } else {
        None
      }
      Json::string(substring(text, from, length, name, at))
    }
    IndexOf => {
      let text = text_argument(name, 0, values[0], at)
      let search = text_argument(name, 1, values[1], at)
      let from = if values.length() > 2 {
        integer_argument(name, 2, values[2], at)
      } else {
        0
      }
      Json::number(index_of(text, search, from).to_double())
    }
    Includes => {
      let text = text_argument(name, 0, values[0], at)
      let search = text_argument(name, 1, values[1], at)
      Json::boolean(text.contains(search))
    }
    Replace | ReplaceAll => {
      let all = helper is ReplaceAll
      let text = text_argument(name, 0, values[0], at)
      let search = text_argument(name, 1, values[1], at)
      let replacement = text_argument(name, 2, values[2], at)
      Json::string(replaced(text, search, replacement, all, name, at))
    }
    Split => {
      let text = text_argument(name, 0, values[0], at)
      let separator = text_argument(name, 1, values[1], at)
      Json::array(split_text(text, separator, name, at))
    }
    Join => {
      guard values[0] is Array(items) else {
        raise RenderError(
          at~,
          message=argument_problem(name, 0, Array, values[0]),
        )
      }
      let separator = text_argument(name, 1, values[1], at)
      Json::string(joined(items, separator, name, at))
    }
    Uppercase | Lowercase => {
      let to_upper = helper is Uppercase
      let text = text_argument(name, 0, values[0], at)
      Json::string(case_mapped(text, to_upper, name, at))
    }
    Trim =>
      Json::string(trimmed(text_argument(name, 0, values[0], at), name, at))
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
/// The code points of `text` from `from`, `length` of them or by default
/// the rest, as `substr`, the helper `name`, inserted at `at` gives them. A negative `from`
/// counts from the end. Positions out of range clamp, so a negative
/// `length` gives an empty text.
fn substring(
  text : String,
  from : Int,
  length : Int?,
  name : String,
  at : String,
) -> String raise RenderError {
  let count = text.char_length()
  let start = if from < 0 {
    if count + from < 0 {
      0
    } else {
      count + from
    }
  } else if from > count {
    count
  } else {
    from
  }
  let rest = count - start
  let taken = match length {
    None => rest
    Some(n) if n < 0 => 0
    Some(n) if n > rest => rest
    Some(n) => n
  }
  let begin = char_offset(text, start, 0)
  let end = char_offset(text, taken, begin)
  let part = text.view(start_offset=begin, end_offset=end)
  check_result(name, utf8_length(part).to_int64(), at)
  part.to_owned()
}

///|
/// The code-point index of the first occurrence of `search` in `text` at or
/// after the code point `from`, or -1 when there is none. A negative `from`
/// counts as 0, and a `from` past the end gives -1.
fn index_of(text : String, search : String, from : Int) -> Int {
  let from = if from < 0 { 0 } else { from }
  if from > text.char_length() {
    return -1
  }
  let begin = char_offset(text, from, 0)
  match text.view(start_offset=begin).find(search) {
    Some(found) =>
      from + text.char_length(start_offset=begin, end_offset=begin + found)
    None => -1
  }
}

///|
/// `text` with the first occurrence of `search`, or every one when `all`,
/// replaced by `replacement`, as the helper `name` inserted at `at` gives
/// it. The occurrences are found from the start, without overlap. Both the
/// search and the replacement are literal text, and an empty search leaves
/// the text unchanged. Either way, the result is bounded before it is
/// built.
fn replaced(
  text : String,
  search : String,
  replacement : String,
  all : Bool,
  name : String,
  at : String,
) -> String raise RenderError {
  let text_bytes = utf8_length(text).to_int64()
  if search == "" {
    check_result(name, text_bytes, at)
    return text
  }
  let mut count = 0
  let mut offset = 0
  while text.view(start_offset=offset).find(search) is Some(found) {
    count += 1
    offset += found + search.length()
    if !all {
      break
    }
  }
  let growth = utf8_length(replacement).to_int64() -
    utf8_length(search).to_int64()
  check_result(name, text_bytes + count.to_int64() * growth, at)
  if count == 0 {
    return text
  }
  let out = StringBuilder()
  offset = 0
  for _ in 0..<count {
    guard text.view(start_offset=offset).find(search) is Some(found) else {
      break
    }
    out.write_view(text.view(start_offset=offset, end_offset=offset + found))
    out.write_string(replacement)
    offset += found + search.length()
  }
  out.write_view(text.view(start_offset=offset))
  out.to_string()
}

///|
/// `text` split at each occurrence of `separator`, as `split`, the helper
/// `name`, inserted at `at` gives it. The occurrences are found from the start, without
/// overlap, and an empty separator splits into code points. An empty text
/// gives one empty string, whatever the separator. The array is bounded, as
/// its compact JSON, before it is built.
fn split_text(
  text : String,
  separator : String,
  name : String,
  at : String,
) -> Array[Json] raise RenderError {
  if text == "" {
    return [Json::string("")]
  }
  // The compact JSON of n strings takes their escaped text, their quotes,
  // the commas between them and the brackets: 3n + 1 bytes more.
  let text_bytes = json_string_content_length(text).to_int64()
  if separator == "" {
    let count = text.char_length()
    check_result(name, text_bytes + 3L * count.to_int64() + 1L, at)
    let items : Array[Json] = Array(capacity=count)
    for c in text {
      items.push(Json::string(c.to_string()))
    }
    return items
  }
  let mut count = 0
  let mut offset = 0
  while text.view(start_offset=offset).find(separator) is Some(found) {
    count += 1
    offset += found + separator.length()
  }
  let separator_bytes = json_string_content_length(separator).to_int64()
  check_result(
    name,
    text_bytes -
    count.to_int64() * separator_bytes +
    3L * (count.to_int64() + 1L) +
    1L,
    at,
  )
  let items : Array[Json] = Array(capacity=count + 1)
  offset = 0
  for _ in 0..<count {
    guard text.view(start_offset=offset).find(separator) is Some(found) else {
      break
    }
    items.push(
      Json::string(
        text.view(start_offset=offset, end_offset=offset + found).to_owned(),
      ),
    )
    offset += found + separator.length()
  }
  items.push(Json::string(text.view(start_offset=offset).to_owned()))
  items
}

///|
/// The elements of `items` written as text, `null` as an empty text, with
/// `separator` between them, as `join`, the helper `name`, inserted at `at`
/// gives them. An
/// object or an array as an element is a render error. The result is
/// bounded before it is built.
fn joined(
  items : Array[Json],
  separator : String,
  name : String,
  at : String,
) -> String raise RenderError {
  let texts = []
  let mut bytes = 0L
  for i, item in items {
    let text = if item is Null {
      ""
    } else if text_value(item) is Some(text) {
      text
    } else {
      raise RenderError(
        at~,
        message="\{name}(): element [\{i}] of argument 1 must be a string, a number, a boolean or null, not \{kind_of(item)}",
      )
    }
    bytes += utf8_length(text).to_int64()
    texts.push(text)
  }
  if texts.length() > 1 {
    bytes += (texts.length() - 1).to_int64() * utf8_length(separator).to_int64()
  }
  check_result(name, bytes, at)
  let out = StringBuilder()
  for i, text in texts {
    if i > 0 {
      out.write_string(separator)
    }
    out.write_string(text)
  }
  out.to_string()
}

///|
/// The offset, in UTF-16 code units, `chars` code points of `text` after
/// the offset `from`, or the end of `text` when fewer follow it.
fn char_offset(text : String, chars : Int, from : Int) -> Int {
  let mut offset = from
  for _ in 0..<chars {
    if offset >= text.length() {
      break
    }
    offset += if text[offset].is_leading_surrogate() &&
      offset + 1 < text.length() &&
      text[offset + 1].is_trailing_surrogate() {
      2
    } else {
      1
    }
  }
  offset
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
/// either end, as `trim`, the helper `name`, inserted at `at` gives it,
/// bounded before it is built.
fn trimmed(
  text : String,
  name : String,
  at : String,
) -> String raise RenderError {
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
  check_result(name, end_bytes - start_bytes, at)
  if start == 0 && end == units {
    text
  } else {
    text[start:end].to_owned()
  }
}
