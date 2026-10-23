// Range requests (RFC 9110, section 14): a response that serves byte
// ranges answers a GET for a single byte range of its body file with 206,
// or with 416 when the range is past the end. Anything else smock ignores,
// and sends the whole body with 200, as RFC 9110 allows.

///|
/// What a request's `Range` field asks for, against a body of a given
/// length.
priv enum ByteRange {
  /// The whole body, with 200: no range, or a `Range` field ignored.
  Whole
  /// The bytes from `first` to `last`, both included, with 206.
  Part(Int32, Int32)
  /// No byte of the body, with 416: the range starts at or past its end,
  /// or is a suffix of 0 bytes.
  Unsatisfiable
}

///|
/// The plan of `response`, a response that serves byte ranges, for
/// `request`:
///
/// - a GET for one satisfiable byte range gets 206, `Content-Range` and
///   those bytes, as a view of the body file's bytes, not a copy;
/// - a GET for one unsatisfiable range gets 416, `Content-Range` with the
///   length alone, and no body;
/// - any other GET, a GET of an empty body, and a HEAD get the whole body
///   with 200.
///
/// The 200 and the 206 carry `Accept-Ranges: bytes`, and every one keeps
/// the response's headers before the fields it adds. A request with any
/// other method gets the response as written.
fn range_response(
  response : @definitions.Response,
  request : Request,
) -> ResponsePlan {
  guard response.body is Bytes(bytes) && request.meth is ("GET" | "HEAD") else {
    return stub_response(response)
  }
  let given = response.headers
  // Room for Content-Range, Accept-Ranges and the Smock-Mock field the
  // Default Mock adds.
  let headers = Array(capacity=given.length() + 3)
  for i in 0..<given.length() {
    headers.push(given[i])
  }
  // RFC 9110 defines range handling for GET only, so a HEAD ignores
  // Range. An empty body has no range to send.
  let length = bytes.length()
  let range = if request.meth == "GET" && length > 0 {
    requested_range(request.headers, length)
  } else {
    Whole
  }
  let mut status = 200
  let mut body : BytesView = bytes
  match range {
    Whole => headers.push(("Accept-Ranges", "bytes"))
    Part(first, last) => {
      headers.push(("Content-Range", "bytes \{first}-\{last}/\{length}"))
      headers.push(("Accept-Ranges", "bytes"))
      status = 206
      body = bytes[first:last + 1]
    }
    Unsatisfiable => {
      headers.push(("Content-Range", "bytes */\{length}"))
      status = 416
      body = b""
    }
  }
  { status, headers, body: Bytes(body), delay_ms: 0, fault: None, }
}

///|
/// The byte range the header fields `headers` ask for, of a body of
/// `length` bytes. More than one `Range` field is the whole body, and so is
/// any `If-Range`: smock has no validators, so RFC 9110 (section 13.1.5)
/// says to ignore `Range` then.
fn requested_range(
  headers : Array[(String, String)],
  length : Int32,
) -> ByteRange {
  let mut value = None
  for i in 0..<headers.length() {
    let name = headers[i].0
    if is_name(name, "range") {
      if value is Some(_) {
        return Whole
      }
      value = Some(headers[i].1)
    } else if is_name(name, "if-range") {
      return Whole
    }
  }
  match value {
    Some(value) => byte_range(value, length)
    None => Whole
  }
}

///|
/// The byte range that the `Range` field value `value` asks for, of a body
/// of `length` bytes, read by RFC 9110's grammar:
///
/// ```text
/// Range        = range-unit "=" range-set
/// range-set    = 1#range-spec
/// range-spec   = int-range / suffix-range / other-range
/// int-range    = first-pos "-" [ last-pos ]
/// suffix-range = "-" suffix-length
/// ```
///
/// Only the unit `bytes`, compared case-insensitively, and a set of one
/// `int-range` or `suffix-range` are served; the list may hold empty
/// elements, as RFC 9110 lets a list do. Anything else, an `int-range`
/// whose last position is below its first included, is the whole body.
fn byte_range(value : String, length : Int32) -> ByteRange {
  guard value.find("=") is Some(eq) && is_name(value[:eq], "bytes") else {
    return Whole
  }
  // The one element of the range set that is not empty. Spaces and tabs
  // may stand on either side of a comma, and nowhere else.
  let set = value[eq + 1:]
  let mut spec_start = -1
  let mut spec_end = -1
  let mut i = 0
  while i <= set.length() {
    let mut end = i
    while end < set.length() && set[end] != ',' {
      end += 1
    }
    let mut first = i
    let mut last = end
    if i > 0 {
      while first < last && is_ows(set[first]) {
        first += 1
      }
    }
    if end < set.length() {
      while last > first && is_ows(set[last - 1]) {
        last -= 1
      }
    }
    if first < last {
      if spec_start >= 0 {
        // Several ranges.
        return Whole
      }
      spec_start = first
      spec_end = last
    }
    i = end + 1
  }
  guard spec_start >= 0 else { return Whole }
  let spec = set[spec_start:spec_end]
  guard spec.find("-") is Some(dash) else { return Whole }
  let first = spec[:dash]
  let last = spec[dash + 1:]
  if first.is_empty() {
    // -suffix: the last bytes, as many as the body has at most.
    guard is_digits(last) else { return Whole }
    let suffix = position(last, length)
    if suffix == 0 {
      return Unsatisfiable
    }
    return Part(length - suffix, length - 1)
  }
  guard is_digits(first) && (last.is_empty() || is_digits(last)) else {
    return Whole
  }
  if !last.is_empty() && is_below(last, first) {
    return Whole
  }
  let first = position(first, length)
  if first >= length {
    return Unsatisfiable
  }
  let last = if last.is_empty() { length } else { position(last, length) }
  Part(first, if last >= length { length - 1 } else { last })
}

///|
/// Whether `c` is a space or a tab, as optional whitespace is.
fn is_ows(c : UInt16) -> Bool {
  c == ' ' || c == '\t'
}

///|
/// Whether `text` is one or more ASCII digits.
fn is_digits(text : StringView) -> Bool {
  if text.is_empty() {
    return false
  }
  for i in 0..<text.length() {
    if text[i] < '0' || text[i] > '9' {
      return false
    }
  }
  true
}

///|
/// Whether the number the digits `a` write is below the one `b` writes,
/// compared exactly, however many digits they have.
fn is_below(a : StringView, b : StringView) -> Bool {
  let a = significant(a)
  let b = significant(b)
  if a.length() != b.length() {
    return a.length() < b.length()
  }
  for i in 0..<a.length() {
    if a[i] != b[i] {
      return a[i] < b[i]
    }
  }
  false
}

///|
/// `digits` without its leading zeros.
fn significant(digits : StringView) -> StringView {
  let mut i = 0
  while i < digits.length() && digits[i] == '0' {
    i += 1
  }
  digits[i:]
}

///|
/// The number the digits `digits` write, or `length` when it is `length` or
/// more, so that no number overflows, however many digits it has.
fn position(digits : StringView, length : Int32) -> Int32 {
  let mut n = 0L
  for i in 0..<digits.length() {
    n = n * 10 + (digits[i] - '0').to_int64()
    if n >= length.to_int64() {
      return length
    }
  }
  n.to_int()
}
