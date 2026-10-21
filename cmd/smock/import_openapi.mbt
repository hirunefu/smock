///|
/// Runs `smock import-openapi`: checks the output, reads the OpenAPI
/// document and the documents its references name, converts them into a
/// Definition file and writes the file. Prints every problem to stdout, one
/// per line, as `smock check` does, then a summary line: `wrote <file>: <n>
/// Stubs from <m> operations, <w> warnings`, or `nothing written: <e>
/// errors`. Returns the exit status: 0 when the file was written, warnings
/// or not, 1 when nothing was written, and 2 for a document outside
/// `--ref-dir`, a usage error printed on stderr.
///
/// The output is checked before the document is read (see
/// `refused_output`), so that a mistyped path never costs a hand-written
/// file, and the refusal comes at once. The documents that references name
/// are known only once read, so an output that is one of them is refused
/// just before writing.
async fn import_openapi(settings : @settings.ImportOpenapiSettings) -> Int {
  let (ref_dir, document_dir) = real_directories(settings)
  let name = settings.document_name_under(ref_dir~, document_dir~) catch {
    err => {
      eprintln("smock import-openapi: \{err.message()}")
      return 2
    }
  }
  let output = settings.output
  if refused_output(settings) is Some(reason) {
    return nothing_written(output, reason)
  }
  let document = settings.document
  let bytes = match
    read_document(document, limit=@importopenapi.max_read_bytes + 1) {
    Ok(bytes) => bytes
    Err(reason) if @importopenapi.has_scheme(document) =>
      return nothing_written(
        document,
        "cannot be read: \{reason}; smock reads no URLs: download the document first",
      )
    Err(reason) => return nothing_written(document, "cannot be read: \{reason}")
  }
  let options = @importopenapi.Options(
    root=name,
    root_label=document,
    ref_dir=settings.ref_dir_path(),
    mock=settings.mock,
    hosts=settings.hosts,
    declare_mock=settings.declare_mock,
    output~,
    base_path?=settings.base_path,
  )
  let converter = @importopenapi.Converter::new(options)
  converter.give(name, bytes)
  let (conversion, read) = converted(
    converter,
    options,
    room=@importopenapi.max_read_bytes - bytes.length(),
  )
  guard conversion is Converted(file~, problems~, stubs~, operations~) else {
    let problems = conversion.problems()
    print_problems(problems)
    let errors = problems.iter().filter(problem => problem.is_error()).count()
    println("nothing written: \{errors} errors")
    return 1
  }
  let refused = if is_read(output, read) {
    Err(
      "is one of the documents being imported, and smock import-openapi does not replace it with its own conversion",
    )
  } else {
    write_atomically(output, file, replace=settings.overwrite).map_err(reason => {
      "cannot be written: \{reason}"
    })
  }
  if refused is Err(reason) {
    // A problem with the output comes before the document's.
    print_problem(output, reason)
    print_problems(problems)
    println("nothing written: 1 errors")
    return 1
  }
  print_problems(problems)
  println(
    "wrote \{output}: \{stubs} Stubs from \{operations} operations, \{problems.length()} warnings",
  )
  0
}

///|
/// Where `--ref-dir`, when it is given and names a directory, and the
/// document's directory really are, once symlinks, `.` and `..` are
/// resolved, or `None` for each that cannot be resolved. The document's
/// name under `--ref-dir` is found from them.
async fn real_directories(
  settings : @settings.ImportOpenapiSettings,
) -> (String?, String?) {
  guard settings.ref_dir is Some(ref_dir) else { return (None, None) }
  let is_directory = try @fs.kind(ref_dir) catch {
    _ => false
  } noraise {
    kind => kind is Directory
  }
  let ref_dir = if is_directory { real_path(ref_dir) } else { None }
  let document_dir = real_path(
    match settings.document_directory() {
      "" => "."
      directory => directory
    },
  )
  (ref_dir, document_dir)
}

///|
/// The real path of `path`, once symlinks, `.` and `..` are resolved, or
/// `None` when it cannot be resolved.
async fn real_path(path : String) -> String? {
  try @fs.realpath(path) catch {
    _ => None
  } noraise {
    real => Some(real)
  }
}

///|
/// Whether the real path `real` is within the directory whose real path is
/// `inside`, below it.
fn within(real : String, inside : String) -> Bool {
  real.has_prefix(under(inside))
}

///|
/// What the real paths within the directory whose real path is `inside`
/// start with: it, then `/`.
fn under(inside : String) -> String {
  if inside.has_suffix("/") {
    inside
  } else {
    "\{inside}/"
  }
}

///|
/// Converts with `converter`, whose options are `options`, until it needs
/// no more documents. Each round reads the documents it asks for, at most
/// `room` bytes in all, or tells it why one cannot be read. Returns what it
/// gave, and the real path of each document read for it.
async fn converted(
  converter : @importopenapi.Converter,
  options : @importopenapi.Options,
  room~ : Int,
) -> (@importopenapi.Conversion, Array[String]) {
  let read = []
  let mut conversion = converter.convert()
  guard conversion is Needs(_) else { return (conversion, read) }
  // Where the directory that references are followed in really is, or why
  // it cannot be found.
  let directory = if options.ref_dir == "" { "." } else { options.ref_dir }
  let inside = try @fs.realpath(directory) catch {
    err => Err(@server.read_failure(err))
  } noraise {
    real => Ok(real)
  }
  let mut room = room
  while conversion is Needs(names) {
    for name in names {
      // One byte more than the room, so that the converter sees the bound
      // passed.
      let limit = room.max(0) + 1
      match read_referenced(options.path(name), inside, limit~) {
        Ok((bytes, real)) => {
          converter.give(name, bytes)
          room -= bytes.length()
          read.push(real)
        }
        Err(reason) => converter.give_unreadable(name, reason)
      }
    }
    conversion = converter.convert()
  }
  (conversion, read)
}

///|
/// The bytes of the document at `path`, which a reference names, at most
/// `limit` of them, and its real path; or why it cannot be read. It must be
/// a regular file within `inside`, the real path of the directory that
/// references are followed in, once symlinks are resolved.
async fn read_referenced(
  path : String,
  inside : Result[String, String],
  limit~ : Int,
) -> Result[(Bytes, String), @importopenapi.Unreadable] {
  let inside = match inside {
    Ok(inside) => inside
    Err(reason) => return Err(Other(reason))
  }
  let kind = @fs.kind(path) catch {
    @os_error.OSError(_) as err if err.is_ENOENT() || err.is_ENOTDIR() =>
      return Err(Missing)
    err => return Err(Other(@server.read_failure(err)))
  }
  guard kind is Regular else { return Err(NotRegularFile) }
  let real = @fs.realpath(path) catch {
    err => return Err(Other(@server.read_failure(err)))
  }
  guard within(real, inside) else { return Err(SymlinkOutside) }
  let bytes = read_at_most(path, limit) catch {
    err => return Err(Other(@server.read_failure(err)))
  }
  Ok((bytes, real))
}

///|
/// Whether `output` is one of the documents whose real paths are `read`.
async fn is_read(output : String, read : Array[String]) -> Bool {
  read.contains(@fs.realpath(output)) catch {
    _ => false
  }
}

///|
/// Prints `problems`, one per line.
fn print_problems(problems : Array[@importopenapi.Problem]) -> Unit {
  for problem in problems {
    println(problem.to_string())
  }
}

///|
/// Prints a problem about the whole of `file`, as `smock check` prints it.
fn print_problem(file : String, message : String) -> Unit {
  println(@definitions.Diagnostic::{ file, pointer: "", message, }.to_string())
}

///|
/// Prints the one problem that stopped the import, about `file`, and the
/// summary line, and returns the exit status 1.
fn nothing_written(file : String, message : String) -> Int {
  println(@definitions.Diagnostic::{ file, pointer: "", message, }.to_string())
  println("nothing written: 1 errors")
  1
}

///|
/// The bytes of the document at `path`, at most `limit` of them, or why it
/// cannot be read, such as `no such file`.
async fn read_document(path : String, limit~ : Int) -> Result[Bytes, String] {
  let is_dir = try @fs.kind(path) catch {
    _ => false
  } noraise {
    kind => kind is Directory
  }
  if is_dir {
    return Err("is a directory")
  }
  try read_at_most(path, limit) catch {
    err => Err(@server.read_failure(err))
  } noraise {
    bytes => Ok(bytes)
  }
}

///|
/// The first `limit` bytes of the file at `path`, or all of it when it is
/// shorter, so that a document larger than the converter reads is never
/// read whole.
async fn read_at_most(path : String, limit : Int) -> Bytes {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let buffer = @buffer.Buffer()
  while buffer.length() < limit {
    let max_len = (limit - buffer.length()).min(1024 * 1024)
    guard file.read_some(max_len~) is Some(chunk) else { break }
    buffer.write_bytes(chunk)
  }
  buffer.to_bytes()
}

///|
/// Why the output of `settings` is refused, if it is, as the message of a
/// problem about it:
/// - its directory does not exist, since the command makes no directory;
/// - it exists and is not a regular file: a directory, or a symlink, even
///   to a regular file;
/// - it is the document, which `--overwrite on` would replace with its own
///   conversion;
/// - it exists, and `--overwrite` is off.
///
/// When the output cannot be looked at, writing it reports why.
async fn refused_output(settings : @settings.ImportOpenapiSettings) -> String? {
  let output = settings.output
  let kind = @fs.kind(output, follow_symlink=false) catch {
    @os_error.OSError(_) as err if err.is_ENOENT() || err.is_ENOTDIR() =>
      return refused_directory(output)
    _ => return None
  }
  match kind {
    Regular => ()
    SymLink =>
      return Some(
        "is a symlink, and smock import-openapi replaces only a regular file",
      )
    Directory =>
      return Some(
        "is a directory, and smock import-openapi replaces only a regular file",
      )
    _ =>
      return Some(
        "is not a regular file, and smock import-openapi replaces only a regular file",
      )
  }
  if same_file(output, settings.document) {
    Some(
      "is the document being imported, and smock import-openapi does not replace it with its own conversion",
    )
  } else if !settings.overwrite {
    Some(
      "already exists, and smock import-openapi replaces a file only with --overwrite on",
    )
  } else {
    None
  }
}

///|
/// Why `output`, which does not exist, is refused, if it is: because its
/// directory does not exist either.
async fn refused_directory(output : String) -> String? {
  let directory = match output.rev_find("/") {
    Some(0) => "/"
    Some(i) => output[:i].to_owned()
    None => "."
  }
  let is_directory = try @fs.kind(directory) catch {
    @os_error.OSError(_) as err if err.is_ENOENT() || err.is_ENOTDIR() => false
    // Writing the output reports why it cannot be looked at.
    _ => true
  } noraise {
    kind => kind is Directory
  }
  if is_directory {
    None
  } else {
    Some("cannot be written: its directory does not exist")
  }
}

///|
/// Whether `a` and `b` name the same file, once symlinks, `.` and `..`
/// are resolved. False when either cannot be resolved.
async fn same_file(a : String, b : String) -> Bool {
  (@fs.realpath(a) == @fs.realpath(b)) catch {
    _ => false
  }
}

///|
/// The most temporary files `write_atomically` tries before it gives up:
/// each is a new file, and one that exists is never touched.
let max_temporary_files : Int = 100

///|
/// Writes `bytes` to `path`, or says why it cannot. The bytes go to a
/// temporary file in the same directory, whose name starts with `.` so that
/// a smock watching the directory skips it, which is then renamed to
/// `path`. So a reader of `path` sees the old file or the new one, never
/// half a file. An existing file at `path` is replaced only when `replace`
/// is true: otherwise the rename does not replace, so a file created there
/// since `refused_output` looked is kept. The temporary file is removed
/// when anything fails, and no other file is touched.
async fn write_atomically(
  path : String,
  bytes : Bytes,
  replace~ : Bool,
) -> Result[Unit, String] {
  let (directory, name) = match path.rev_find("/") {
    Some(i) => (path[:i + 1].to_owned(), path[i + 1:].to_owned())
    None => ("", path)
  }
  for n in 0..<max_temporary_files {
    let temporary = if n == 0 {
      "\{directory}.\{name}.tmp"
    } else {
      "\{directory}.\{name}.tmp\{n}"
    }
    let file = @fs.open(
      temporary,
      mode=WriteOnly,
      create_mode=CreateNew,
      sync=Data,
    ) catch {
      // Another file, which is not this command's to touch.
      @os_error.OSError(_) as err if err.is_EEXIST() => continue
      err => return Err(write_failure(err))
    }
    // From here on, the temporary file is this command's own.
    return try {
      write_and_close(file, bytes)
      @fs.rename(temporary, path, replace~)
    } catch {
      err => {
        @fs.remove(temporary) catch {
          _ => ()
        }
        Err(write_failure(err))
      }
    } noraise {
      _ => Ok(())
    }
  }
  Err(
    "the temporary files .\{name}.tmp to .\{name}.tmp\{max_temporary_files - 1} all exist",
  )
}

///|
/// Writes `bytes` to `file`, then closes it, even when the write fails.
async fn write_and_close(file : @fs.File, bytes : Bytes) -> Unit {
  defer file.close()
  file.write(bytes)
}

///|
/// The message of a problem about an output that `err` stopped from being
/// written.
fn write_failure(err : Error) -> String {
  match err {
    @os_error.OSError(_) as err if err.is_EEXIST() =>
      "it exists now, and is not replaced"
    @os_error.OSError(_) as err if err.is_ENOENT() =>
      "its directory does not exist"
    err => @server.read_failure(err)
  }
}
