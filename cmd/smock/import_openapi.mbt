///|
/// Runs `smock import-openapi`: checks the output, reads the OpenAPI
/// document, converts it into a Definition file and writes the file. Prints
/// every problem to stdout, one per line, as `smock check` does, then a
/// summary line: `wrote <file>: <n> Stubs from <m> operations, <w>
/// warnings`, or `nothing written: <e> errors`. Returns the exit status: 0
/// when the file was written, warnings or not, and 1 when nothing was
/// written.
///
/// The output is checked before the document is read (see
/// `refused_output`), so that a mistyped path never costs a hand-written
/// file, and the refusal comes at once.
async fn import_openapi(settings : @settings.ImportOpenapiSettings) -> Int {
  let output = settings.output
  if refused_output(settings) is Some(reason) {
    return nothing_written(output, reason)
  }
  let document = settings.document
  let bytes = match read_document(document) {
    Ok(bytes) => bytes
    Err(reason) => return nothing_written(document, "cannot be read: \{reason}")
  }
  let name = settings.document_name()
  let conversion = @importopenapi.convert(
    [(name, bytes)],
    @importopenapi.Options(
      root=name,
      root_label=document,
      mock=settings.mock,
      output~,
      base_path?=settings.base_path,
    ),
  )
  match conversion {
    Failed(problems) => {
      print_problems(problems)
      let errors = problems.iter().filter(problem => problem.is_error()).count()
      println("nothing written: \{errors} errors")
      1
    }
    Converted(file~, problems~, stubs~, operations~) => {
      if write_atomically(output, file, replace=settings.overwrite)
        is Err(reason) {
        // A problem with the output comes before the document's.
        print_problem(output, "cannot be written: \{reason}")
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
/// The bytes of the document at `path`, or why it cannot be read, such as
/// `no such file`.
async fn read_document(path : String) -> Result[Bytes, String] {
  let is_dir = try @fs.kind(path) catch {
    _ => false
  } noraise {
    kind => kind is Directory
  }
  if is_dir {
    return Err("is a directory")
  }
  try @fs.read_file(path).binary() catch {
    err => Err(@server.read_failure(err))
  } noraise {
    bytes => Ok(bytes)
  }
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
