// When a certificate expires, read from its PEM in MoonBit: the validity of
// an X.509 certificate is plain DER, so no C is needed for it (ADR 0001).
// OpenSSL has checked the certificate by the time it is presented; this
// only reads its notAfter.

///|
/// When the first certificate in `pem` expires: its notAfter, in
/// milliseconds since the Unix epoch. `None` when `pem` holds no
/// certificate that can be read.
fn certificate_expiry(pem : Bytes) -> Int64? {
  guard first_certificate_der(pem) is Some(der) else { return None }
  // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signature }
  guard der_element(der, 0) is Some((0x30, certificate, _)) &&
    der_element(certificate, 0) is Some((0x30, tbs, _)) else {
    return None
  }
  // TBSCertificate ::= SEQUENCE { [0] version OPTIONAL, serialNumber,
  //   signature, issuer, validity, ... }
  let mut pos = 0
  if der_element(tbs, pos) is Some((0xa0, _, next)) {
    pos = next
  }
  // serialNumber, signature and issuer.
  for _ in 0..<3 {
    guard der_element(tbs, pos) is Some((_, _, next)) else { return None }
    pos = next
  }
  // Validity ::= SEQUENCE { notBefore Time, notAfter Time }
  guard der_element(tbs, pos) is Some((0x30, validity, _)) &&
    der_element(validity, 0) is Some((_, _, after_not_before)) &&
    der_element(validity, after_not_before) is Some((tag, not_after, _)) else {
    return None
  }
  der_time(tag, not_after)
}

///|
/// The DER bytes of the first PEM block in `pem` whose label ends with
/// `CERTIFICATE`.
fn first_certificate_der(pem : Bytes) -> BytesView? {
  let base64 = StringBuilder()
  let mut inside = false
  for line in @utf8.decode_lossy(pem).split("\n") {
    let line = line.trim(chars=" \t\r")
    if inside {
      if line.has_prefix("-----END ") {
        let der = @base64.decode(base64.to_string(), ignore_whitespace=true) catch {
          _ => return None
        }
        return Some(der[:])
      }
      base64.write_string(line.to_owned())
    } else if line.has_prefix("-----BEGIN ") &&
      line.has_suffix("CERTIFICATE-----") {
      inside = true
    }
  }
  None
}

///|
/// The DER element that starts at `pos` in `data`: its tag, its contents
/// and where the next element starts. `None` when it does not fit.
fn der_element(data : BytesView, pos : Int32) -> (Int32, BytesView, Int32)? {
  if pos + 2 > data.length() {
    return None
  }
  let tag = data[pos].to_int()
  let first = data[pos + 1].to_int()
  let mut start = pos + 2
  let mut length = first
  if first >= 0x80 {
    // The long form: the low bits say how many bytes hold the length.
    let count = first - 0x80
    if count < 1 || count > 3 || start + count > data.length() {
      return None
    }
    length = 0
    for i in 0..<count {
      length = length * 256 + data[start + i].to_int()
    }
    start += count
  }
  let end = start + length
  if end > data.length() {
    return None
  }
  Some((tag, data[start:end], end))
}

///|
/// A UTCTime (tag 0x17, `YYMMDDHHMMSSZ`) or GeneralizedTime (tag 0x18,
/// `YYYYMMDDHHMMSSZ`) as DER writes them, in milliseconds since the Unix
/// epoch: read as the RFC 3339 date-time with the same fields.
fn der_time(tag : Int32, value : BytesView) -> Int64? {
  let digits = match (tag, value.length()) {
    (0x17, 13) | (0x18, 15) => value[:value.length() - 1]
    _ => return None
  }
  if value[value.length() - 1] != b'Z' ||
    !digits.iter().all(b => b >= b'0' && b <= b'9') {
    return None
  }
  let year_first = if tag == 0x17 {
    // RFC 5280, section 4.1.2.5.1: a UTCTime year below 50 is in the 2000s.
    if digits[0] < b'5' {
      "20"
    } else {
      "19"
    }
  } else {
    ""
  }
  // YYYYMMDDHHMMSS, punctuated as YYYY-MM-DDTHH:MM:SSZ.
  let d = year_first + @utf8.decode_lossy(digits)
  @log.parse_time(
    "\{d[0:4]}-\{d[4:6]}-\{d[6:8]}T\{d[8:10]}:\{d[10:12]}:\{d[12:14]}Z",
  )
}
