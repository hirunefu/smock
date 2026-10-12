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
fn der_element(data : BytesView, pos : Int) -> (Int, BytesView, Int)? {
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
/// epoch.
fn der_time(tag : Int, value : BytesView) -> Int64? {
  let digits = match (tag, value.length()) {
    (0x17, 13) | (0x18, 15) => value[:value.length() - 1]
    _ => return None
  }
  if value[value.length() - 1] != b'Z' {
    return None
  }
  let numbers : Array[Int64] = []
  for b in digits {
    if b < b'0' || b > b'9' {
      return None
    }
    numbers.push((b - b'0').to_int64())
  }
  let two = (i : Int) => numbers[i] * 10L + numbers[i + 1]
  // RFC 5280, section 4.1.2.5.1: a UTCTime year below 50 is in the 2000s.
  let (year, rest) = if tag == 0x17 {
    let yy = two(0)
    (if yy < 50L { 2000L + yy } else { 1900L + yy }, 2)
  } else {
    (two(0) * 100L + two(2), 4)
  }
  let month = two(rest)
  let day = two(rest + 2)
  let hour = two(rest + 4)
  let minute = two(rest + 6)
  let second = two(rest + 8)
  if month < 1L ||
    month > 12L ||
    day < 1L ||
    day > 31L ||
    hour > 23L ||
    minute > 59L ||
    second > 60L {
    return None
  }
  let days = days_from_civil(year, month, day)
  Some(((days * 24L + hour) * 60L + minute) * 60_000L + second * 1000L)
}

///|
/// The number of days from 1970-01-01 to the given date of the proleptic
/// Gregorian calendar, after Howard Hinnant's `days_from_civil`.
fn days_from_civil(year : Int64, month : Int64, day : Int64) -> Int64 {
  let y = if month <= 2L { year - 1L } else { year }
  let era = (if y >= 0L { y } else { y - 399L }) / 400L
  let yoe = y - era * 400L
  let mp = if month > 2L { month - 3L } else { month + 9L }
  let doy = (153L * mp + 2L) / 5L + day - 1L
  let doe = yoe * 365L + yoe / 4L - yoe / 100L + doy
  era * 146_097L + doe - 719_468L
}
