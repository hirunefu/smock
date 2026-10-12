///|
/// The state of decoding one chunked body (RFC 9112, section 7.1), kept
/// between calls so that each byte is looked at once however the body
/// arrives, and so that the bytes looked at need not be kept.
priv struct Chunks {
  mut state : ChunkState
  /// The size of the chunk being read, then the bytes of its data still to
  /// come.
  mut size : Int
  /// The data of the chunks decoded so far.
  mut body : @buffer.Buffer
  /// The longest body allowed, below `max_length`.
  limit : Int
}

///|
priv enum ChunkState {
  /// The first digit of a chunk size is next.
  SizeStart
  /// In the digits of a chunk size.
  Size
  /// In whitespace that must be followed by `;`.
  ExtBws
  /// The name of a chunk extension is next, after optional whitespace.
  ExtNameStart
  /// In the name of a chunk extension.
  ExtName
  /// In whitespace after the name of a chunk extension.
  ExtAfterName
  /// The value of a chunk extension is next, after optional whitespace.
  ExtValueStart
  /// In a token value of a chunk extension.
  ExtToken
  /// In a quoted-string value of a chunk extension.
  ExtQuoted
  /// After a backslash in a quoted-string value.
  ExtQuotedPair
  /// Just after a quoted-string value.
  ExtAfterQuoted
  /// The LF ending the chunk-size line is next.
  SizeLf
  /// In the data of a chunk.
  Data
  /// The CR after the data of a chunk is next.
  DataCr
  /// The LF after the data of a chunk is next.
  DataLf
  /// In the trailer section, which ends the body.
  Trailer(Section)
  /// The byte just looked at breaks the framing.
  Broken
}

///|
fn Chunks::Chunks(limit~ : Int) -> Chunks {
  { state: SizeStart, size: 0, body: @buffer.Buffer(), limit, }
}

///|
/// Hands over the decoded body and gets ready for the next one.
fn Chunks::take_body(self : Chunks) -> Bytes {
  let body = self.body.to_bytes()
  self.state = SizeStart
  self.size = 0
  self.body = @buffer.Buffer()
  body
}

///|
/// Decodes `buf[start:end]`, the bytes of the chunked body that follow those
/// the last calls decoded. Returns how many of them the body takes once its
/// end has arrived, `None` when all of them are decoded and more are needed,
/// or the status of the error that breaks its framing.
fn Chunks::decode(
  self : Chunks,
  buf : FixedArray[Byte],
  start : Int,
  end : Int,
) -> Result[Int?, Int] {
  let mut i = start
  while i < end {
    let c = buf[i]
    match self.state {
      SizeStart =>
        match hex_value(c) {
          Some(digit) => {
            self.size = digit
            self.state = Size
          }
          None => return Err(400)
        }
      Size =>
        match hex_value(c) {
          Some(digit) =>
            // A size too large to hold stays saturated; the end of its line
            // turns it into 413.
            self.size = if self.size > (max_length - digit) / 16 {
              max_length
            } else {
              self.size * 16 + digit
            }
          None => self.state = after_value(c)
        }
      // chunk-ext = *( BWS ";" BWS chunk-ext-name [ BWS "=" BWS chunk-ext-val ] )
      ExtBws =>
        self.state = match c {
          b' ' | b'\t' => ExtBws
          b';' => ExtNameStart
          _ => Broken
        }
      ExtNameStart =>
        self.state = match c {
          b' ' | b'\t' => ExtNameStart
          _ if is_tchar(c) => ExtName
          _ => Broken
        }
      ExtName =>
        self.state = match c {
          _ if is_tchar(c) => ExtName
          b' ' | b'\t' => ExtAfterName
          b'=' => ExtValueStart
          _ => after_value(c)
        }
      ExtAfterName =>
        self.state = match c {
          b' ' | b'\t' => ExtAfterName
          b'=' => ExtValueStart
          b';' => ExtNameStart
          _ => Broken
        }
      ExtValueStart =>
        self.state = match c {
          b' ' | b'\t' => ExtValueStart
          b'"' => ExtQuoted
          _ if is_tchar(c) => ExtToken
          _ => Broken
        }
      ExtToken =>
        self.state = if is_tchar(c) { ExtToken } else { after_value(c) }
      ExtQuoted =>
        self.state = match c {
          b'"' => ExtAfterQuoted
          b'\\' => ExtQuotedPair
          b'\t' | b' ' | b'!' | b'#'..=b'[' | b']'..=b'~' | b'\x80'..=b'\xff' =>
            ExtQuoted
          _ => Broken
        }
      ExtQuotedPair =>
        self.state = match c {
          b'\t' | b' '..=b'~' | b'\x80'..=b'\xff' => ExtQuoted
          _ => Broken
        }
      ExtAfterQuoted => self.state = after_value(c)
      SizeLf => {
        guard c == b'\n' else { return Err(400) }
        if self.size > self.limit - self.body.length() {
          return Err(413)
        }
        self.state = if self.size == 0 { Trailer(FieldStart) } else { Data }
      }
      Data => {
        let take = if self.size < end - i { self.size } else { end - i }
        self.body.write_bytes(buf.unsafe_reinterpret_as_bytes()[i:i + take])
        self.size -= take
        i += take
        if self.size == 0 {
          self.state = DataCr
        }
        continue
      }
      DataCr => {
        guard c == b'\r' else { return Err(400) }
        self.state = DataLf
      }
      DataLf => {
        guard c == b'\n' else { return Err(400) }
        self.state = SizeStart
      }
      // trailer-section = *( field-line CRLF ), as in the header section;
      // its fields are ignored.
      Trailer(section) =>
        match section.after(c) {
          Ended => return Ok(Some(i + 1 - start))
          Broken => return Err(400)
          section => self.state = Trailer(section)
        }
      Broken => ()
    }
    if self.state is Broken {
      return Err(400)
    }
    i += 1
  }
  Ok(None)
}

///|
/// One more than the longest body limit the parser takes. Chunk sizes too
/// large to hold saturate at it.
let max_length : Int = 0x7fffffff

///|
/// The state after `c`, which follows a chunk size or a chunk extension.
fn after_value(c : Byte) -> ChunkState {
  match c {
    b' ' | b'\t' => ExtBws
    b';' => ExtNameStart
    b'\r' => SizeLf
    _ => Broken
  }
}

///|
/// The value of the hexadecimal digit `c`.
fn hex_value(c : Byte) -> Int? {
  match c {
    b'0'..=b'9' => Some((c - b'0').to_int())
    b'a'..=b'f' => Some((c - b'a').to_int() + 10)
    b'A'..=b'F' => Some((c - b'A').to_int() + 10)
    _ => None
  }
}
