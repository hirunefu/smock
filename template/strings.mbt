// The string helpers. Lengths count Unicode code points, so an emoji or a
// Japanese character counts as one.

///|
/// A string helper.
priv enum StringHelper {
  /// `len(x)`: the length of a text or an array.
  Len
  /// `concat(a, b, …)`: texts joined.
  Concat
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
  }
}
