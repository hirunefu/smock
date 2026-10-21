///|
/// The largest file the converter writes: 64 MiB. smock serve holds the
/// whole definition set in memory.
let max_file_bytes : Int = 64 * 1024 * 1024

///|
/// The Definition file of the imported operations, unless a problem so far
/// is an error. The file declares the one Mock, then each Stub, as JSON
/// with two spaces per level and smock's number rule. It must load, with
/// the loader `smock check` uses, as a set of its own, and give no warning.
fn Report::file(self : Report, imported : Array[Imported]) -> Conversion {
  if self.errors > 0 {
    return Failed(self.problems)
  }
  let stubs = []
  for operation in imported {
    for stub in operation.stubs {
      stubs.push(stub.to_json(self.options.mock))
    }
  }
  let file : Json = {
    "version": 1,
    "mocks": [{ "name": self.options.mock }],
    "stubs": Json::array(stubs),
  }
  let bytes = @template.indented_json_bytes(file) + b"\n"
  if !self.checked(bytes, max_bytes=max_file_bytes) {
    return Failed(self.problems)
  }
  Converted(
    file=bytes,
    problems=self.problems,
    stubs=stubs.length(),
    operations=imported.length(),
  )
}

///|
/// A Stub of the Mock `mock` as the file writes it: `id`, `mock`, `request`
/// (`method`, `path`), then `response` (`status`).
fn Stub::to_json(self : Stub, mock : String) -> Json {
  {
    "id": self.id,
    "mock": mock,
    "request": { "method": self.meth, "path": self.path },
    "response": { "status": self.status.to_json() },
  }
}

///|
/// Whether `bytes`, the file, is at most `max_bytes` long and loads as a
/// set of its own with no problem and no warning. Each problem it gives is
/// reported as an error with the file, which is a smock bug. Problems with
/// the file come before the others.
fn Report::checked(self : Report, bytes : Bytes, max_bytes~ : Int) -> Bool {
  let output = self.options.output
  if bytes.length() > max_bytes {
    self.output_error(
      "",
      "the file would be \{bytes.length()} bytes, more than \{size_text(max_bytes)}",
    )
    return false
  }
  match @definitions.load({ files: [(output, bytes)], body_files: [], }) {
    Ok(snapshot) =>
      for warning in snapshot.warnings() {
        self.output_error(
          warning.pointer,
          "smock bug: the file would give the warning: \{warning.message}",
        )
      }
    Err(diagnostics) =>
      for diagnostic in diagnostics {
        self.output_error(
          diagnostic.pointer,
          "smock bug: the file would not load: \{diagnostic.message}",
        )
      }
  }
  self.errors == 0
}

///|
/// `bytes` as a size: in MiB when it is a whole number of them, such as
/// `64 MiB`, else in bytes.
fn size_text(bytes : Int) -> String {
  let mib = 1024 * 1024
  if bytes >= mib && bytes % mib == 0 {
    "\{bytes / mib} MiB"
  } else {
    "\{bytes} bytes"
  }
}
