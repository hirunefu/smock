// The response encoding of an HTTP/2 stream: the header fields of the
// response the engine's plan describes, which the connection's `Conn`
// compresses into HEADERS, with the body sent as DATA after them.

///|
/// The header fields of the HTTP/2 response with the status `status`, the
/// header fields `headers` and a body of `length` octets: `:status`, then
/// each of `headers` with its name in lower case and its value as the UTF-8
/// octets the HTTP/1.1 encoder writes, then `date` with the value `date`,
/// unless `headers` give one, and `content-length`.
fn response_fields(
  status : Int32,
  headers : ArrayView[(String, String)],
  length : Int32,
  date~ : String,
) -> Array[@header.Header] {
  let fields = Array(capacity=headers.length() + 3)
  fields.push(@header.Header::{ name: b":status", value: decimal(status), })
  let mut has_date = false
  for header in headers {
    let name = lower_case(header.0)
    if name == b"date" {
      has_date = true
    }
    fields.push({ name, value: @utf8.encode(header.1), })
  }
  if !has_date {
    fields.push({ name: b"date", value: @utf8.encode(date), })
  }
  fields.push({ name: b"content-length", value: decimal(length), })
  fields
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
