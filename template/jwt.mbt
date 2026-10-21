// The JWT helpers, `jwtPayload` and `jwtHeader`. They decode a JWS compact
// token (RFC 7515 §7.1) and never check its signature. A token that is not
// one is missing, so `??` gives a fallback.

///|
/// A JWT helper: which part of the token it gives.
priv enum JwtHelper {
  /// `jwtPayload(token)`.
  Payload
  /// `jwtHeader(token)`.
  Header
}

///|
/// The JWT helper that `site` calls, checked. `None` when it calls a
/// helper of another family.
fn jwt_helper(site : CallSite) -> Helper? raise Syntax {
  let helper : JwtHelper = match site.name {
    "jwtPayload" => Payload
    "jwtHeader" => Header
    _ => return None
  }
  site.takes([Text], least=1, most=1)
  Some(Jwt(helper))
}

///|
/// What the JWT helper `helper` gives for the values of its arguments,
/// `values`, inserted at `at`: the payload or the header of the token, as
/// a JSON object, or `None` when the value is not a token. Only a part
/// that takes more than 1 MiB as compact JSON is an error.
fn jwt_value(
  helper : JwtHelper,
  values : Array[Json],
  at : String,
) -> Json? raise RenderError {
  guard text_value(values[0]) is Some(text) else { return None }
  let token = without_bearer(text)
  // The two dots that separate the three parts.
  let mut first = -1
  let mut second = -1
  for i in 0..<token.length() {
    if token[i] == '.' {
      if first < 0 {
        first = i
      } else if second < 0 {
        second = i
      } else {
        return None
      }
    }
  }
  if second < 0 {
    return None
  }
  guard jwt_object(token[:first]) is Some(header) else { return None }
  guard jwt_object(token[first + 1:second]) is Some(payload) else {
    return None
  }
  ignore(base64_length(token[second + 1:], true)) catch {
    NotDecodable(_) => return None
  }
  let of_payload = helper is Payload
  let name = if of_payload { "jwtPayload" } else { "jwtHeader" }
  let part = if of_payload { payload } else { header }
  // A part is measured once parsed: as compact JSON, it can take more or
  // fewer bytes than the text it was parsed from.
  check_result(name, compact_length(part), at)
  Some(part)
}

///|
/// `text` without a leading `Bearer`, in any case, when spaces or tabs
/// follow it, and without them. Otherwise `text` as it is.
fn without_bearer(text : String) -> StringView {
  let word = "bearer"
  let mut end = word.length()
  if text.length() <= end {
    return text
  }
  for i in 0..<end {
    let unit = text[i].to_int()
    let lower = if unit >= 'A'.to_int() && unit <= 'Z'.to_int() {
      unit + 32
    } else {
      unit
    }
    if lower != word[i].to_int() {
      return text
    }
  }
  while end < text.length() && text[end] is (' ' | '\t') {
    end += 1
  }
  if end == word.length() {
    text
  } else {
    text[end:]
  }
}

///|
/// The JSON object that `part`, one of the first two parts of a token,
/// holds: base64url, padding optional, of the UTF-8 of a JSON object.
/// `None` when it holds no object. A name that repeats keeps its last
/// value.
fn jwt_object(part : StringView) -> Json? {
  let length = base64_length(part, true) catch { _ => return None }
  let text = @utf8.decode(base64_decoded(part, true, length)) catch {
    _ => return None
  }
  try @json.parse(text) catch {
    _ => None
  } noraise {
    Object(_) as object => Some(object)
    _ => None
  }
}
