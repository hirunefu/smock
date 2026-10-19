// `session_of` as it was before it read the header with index loops, kept
// as the oracle for the one of today: for any header fields, both must
// find the same Session.

///|
fn reference_session_of(
  headers : Array[(String, String)],
  header~ : String,
  member_name~ : String,
) -> String? {
  let header = header.to_lower()
  let mut found = None
  for field in headers {
    if !is_name(field.0, header) {
      continue
    }
    for list_member in field.1.split(",") {
      if list_member.trim(chars=" \t").is_empty() {
        continue
      }
      let key_value = match list_member.find(";") {
        Some(i) => list_member[:i]
        None => list_member
      }
      guard key_value.find("=") is Some(i) else { return None }
      let key = key_value[:i].trim(chars=" \t")
      let value = key_value[i + 1:].trim(chars=" \t")
      if !@http1.is_token(key) || !reference_is_baggage_value(value) {
        return None
      }
      if found is None && key == member_name {
        found = Some(value)
      }
    }
  }
  match found {
    Some(value) if !value.is_empty() => Some(percent_decode(value))
    _ => None
  }
}

///|
fn reference_is_baggage_value(s : StringView) -> Bool {
  for i, c in s {
    let allowed = c > ' ' && c <= '~' && !"\",;\\".contains_char(c)
    if !allowed {
      return false
    }
    if c == '%' && !(i + 2 < s.length() && is_hex(s[i + 1]) && is_hex(s[i + 2])) {
      return false
    }
  }
  true
}

///|
/// Pieces of baggage header values: member names, the Session member,
/// values, separators, whitespace, percent escapes good and bad, and
/// characters W3C Baggage does not allow, beyond ASCII included.
let baggage_pieces : Array[String] = [
  "smock-session", "smock-session", "tenant", "k", "=", "=", "=", "a", "s1", "bench-catalog-item",
  "%41", "%c3%A9", "%4", "%zz", "%", ",", ",", ";", ";p=1", " ", "\t", "\"", "\\",
  "/", "é", "😀", "+", "",
]

///|
test "session_of finds the Session session_of found before it read the header with index loops, for any header fields" {
  let rand = @random.Rand::chacha8(seed=b"smock engine session reference!!")
  let names = ["baggage", "Baggage", "BAGGAGE", "other", "baggage2"]
  let differ = []
  let found = Map([])
  for _ in 0..<20000 {
    let headers = []
    for _ in 0..<(1 + rand.int(limit=3)) {
      let value = StringBuilder()
      for _ in 0..<rand.int(limit=10) {
        value.write_string(
          baggage_pieces[rand.int(limit=baggage_pieces.length())],
        )
      }
      headers.push((names[rand.int(limit=names.length())], value.to_string()))
    }
    let (header, member_name) = if rand.int(limit=4) == 0 {
      ("Baggage", "k")
    } else {
      ("baggage", "smock-session")
    }
    let expected = reference_session_of(headers, header~, member_name~)
    let actual = session_of(headers, header~, member_name~)
    if actual != expected && differ.length() < 5 {
      differ.push((headers, expected, actual))
    }
    found[expected is Some(_)] = true
  }
  debug_inspect(differ, content="[]")
  // Some fields carry a Session and some do not.
  debug_inspect(found.length(), content="2")
}
