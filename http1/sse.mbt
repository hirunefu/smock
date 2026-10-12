///|
/// Encodes one Server-Sent Event as the body of a `text/event-stream`
/// response carries it (HTML Living Standard, "Server-sent events"): its
/// `event` field when `event` is given, its `id` field when `id` is given,
/// one `data` field per line of `data`, and the blank line that ends the
/// event. Lines of `data` end at CRLF, LF or CR, as a client reads them, so
/// the client gets `data` back with each line break as LF. The text is
/// written as UTF-8.
///
/// The caller passes an `event` without CR or LF, and an `id` without CR,
/// LF or NUL: a client would read anything else differently.
///
/// Write the events as parts of a `ResponseStream`.
///
/// ```mbt check
/// test {
///   let bytes = @http1.encode_sse_event("line 1\nline 2", event="update", id="7")
///   inspect(
///     @utf8.decode_lossy(bytes),
///     content="event: update\nid: 7\ndata: line 1\ndata: line 2\n\n",
///   )
/// }
/// ```
pub fn encode_sse_event(data : String, event? : String, id? : String) -> Bytes {
  let out = @buffer.Buffer(size_hint=data.length() + 16)
  if event is Some(event) {
    write_field(out, "event", event)
  }
  if id is Some(id) {
    write_field(out, "id", id)
  }
  for line in lines(data) {
    write_field(out, "data", line)
  }
  out.write_bytes(b"\n")
  out.to_bytes()
}

///|
/// Writes the field `name` with `value` and the LF that ends it. A space
/// separates them, so a value that starts with a space keeps it; an empty
/// value gets none.
fn write_field(out : @buffer.Buffer, name : String, value : StringView) -> Unit {
  out.write_string_utf8(name)
  out.write_byte(b':')
  if !value.is_empty() {
    out.write_byte(b' ')
    out.write_string_utf8(value)
  }
  out.write_byte(b'\n')
}

///|
/// The lines of `text`, split where an event stream ends a line: at CRLF,
/// LF or CR. Text that ends with a line break has an empty last line.
fn lines(text : String) -> Array[StringView] {
  let out = []
  let mut start = 0
  let mut i = 0
  while i < text.length() {
    match text[i] {
      '\n' => {
        out.push(text[start:i])
        start = i + 1
      }
      '\r' => {
        out.push(text[start:i])
        if i + 1 < text.length() && text[i + 1] == '\n' {
          i += 1
        }
        start = i + 1
      }
      _ => ()
    }
    i += 1
  }
  out.push(text[start:])
  out
}
