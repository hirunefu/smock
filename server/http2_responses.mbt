// The response encoding of an HTTP/2 stream: the header fields of the
// response the engine's plan describes, adapted to HTTP/2's rules, which
// the connection's `Conn` compresses into HEADERS, with the body sent as
// DATA after them.

///|
/// The header fields of the HTTP/2 response with the status `status`, the
/// header fields `headers` and a body of `length` octets, to a CONNECT when
/// `connect` is true: `:status`, then each of `headers` with its name in
/// lower case and its value trimmed of spaces and tabs, then `date` with
/// the value `date`, unless `headers` give one, and `content-length`,
/// unless the response has no content (`has_content`). With `streamed`,
/// the body is a stream of Server-Sent Events, whose length is not known
/// when the HEADERS go out, so there is no `content-length`, and `length`
/// is not used.
///
/// Names and values are the octets the HTTP/1.1 encoder writes. The fields
/// HTTP/2 forbids in a response (RFC 9113, section 8.2.2) are left out:
/// `keep-alive`, `upgrade`, `proxy-connection` and `te`, which a Stub may
/// give, and `connection` and `transfer-encoding`, which it may not.
fn response_fields(
  status : Int32,
  headers : ArrayView[(String, String)],
  length : Int32,
  date~ : String,
  connect~ : Bool = false,
  streamed~ : Bool = false,
) -> Array[@header.Header] {
  let fields = Array(capacity=headers.length() + 3)
  fields.push(@header.Header::{ name: b":status", value: decimal(status), })
  let mut has_date = false
  for header in headers {
    let name = lower_case(header.0)
    if is_connection_specific(name) {
      continue
    }
    if name == b"date" {
      has_date = true
    }
    fields.push({ name, value: @http1.field_octets(trimmed(header.1)), })
  }
  if !has_date {
    fields.push({ name: b"date", value: @http1.field_octets(date), })
  }
  if has_content(status, connect~) && !streamed {
    fields.push({ name: b"content-length", value: decimal(length), })
  }
  fields
}

///|
/// Whether a response with `status`, to a CONNECT when `connect` is true,
/// has content: one with status 1xx, 204 or 304 has none, so it has neither
/// `content-length` nor DATA, as on HTTP/1.1 (`@http1.has_content`; RFC
/// 9110, section 8.6). Nor has a 2xx to a CONNECT, after which the stream
/// would carry a tunnel (RFC 9110, section 9.3.6), which smock never opens.
fn has_content(status : Int32, connect~ : Bool = false) -> Bool {
  @http1.has_content(status) && !(connect && status is (200..<=299))
}

///|
/// Whether `name`, a field name in lower case, is one that HTTP/2 forbids
/// in a response, since it is specific to an HTTP/1.1 connection (RFC 9113,
/// section 8.2.2).
fn is_connection_specific(name : Bytes) -> Bool {
  // By length first, so that most names are told apart without a
  // comparison of their octets.
  match name.length() {
    2 => name == b"te"
    7 => name == b"upgrade"
    10 => name == b"keep-alive" || name == b"connection"
    16 => name == b"proxy-connection"
    17 => name == b"transfer-encoding"
    _ => false
  }
}

///|
/// `value` without the spaces and tabs at either end, which HTTP/2 does not
/// allow there (RFC 9113, section 8.2.1). A value without them is returned
/// as it is.
fn trimmed(value : String) -> String {
  let mut start = 0
  let mut end = value.length()
  while start < end && @http1.is_space_or_tab(value[start]) {
    start += 1
  }
  while end > start && @http1.is_space_or_tab(value[end - 1]) {
    end -= 1
  }
  if start == 0 && end == value.length() {
    value
  } else {
    value.view(start_offset=start, end_offset=end).to_owned()
  }
}

///|
/// The octets of `name`, a field name and so a token, which is ASCII, with
/// its letters in lower case, as HTTP/2 sends field names (RFC 9113,
/// section 8.2.1).
fn lower_case(name : String) -> Bytes {
  let out = FixedArray::make(name.length(), b'\x00')
  for i in 0..<name.length() {
    let c = name[i].to_int()
    out[i] = (if c >= 0x41 && c <= 0x5a { c + 0x20 } else { c }).to_byte()
  }
  out.unsafe_reinterpret_as_bytes()
}

///|
/// `n`, a number that is not negative, in decimal digits.
fn decimal(n : Int32) -> Bytes {
  @utf8.encode(n.to_string())
}
