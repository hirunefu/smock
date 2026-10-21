///|
/// Runs `smock import-openapi`: reads the OpenAPI document, converts it
/// into a Definition file and writes the file, created new. Prints every
/// problem to stdout, one per line, as `smock check` does, then a summary
/// line: `wrote <file>: <n> Stubs from <m> operations, <w> warnings`, or
/// `nothing written: <e> errors`. Returns the exit status: 0 when the file
/// was written, warnings or not, and 1 when nothing was written.
///
/// An existing output is refused before the document is read, so that a
/// mistyped path never costs a hand-written file.
async fn import_openapi(settings : @settings.ImportOpenapiSettings) -> Int {
  let output = settings.output
  // When the output cannot be looked at, writing it reports why.
  if (@fs.exists(output) catch { _ => false }) {
    return nothing_written(
      output, "already exists, and smock import-openapi does not replace a file",
    )
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
      if write_new(output, file) is Err(reason) {
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
/// Writes `bytes` to a new file at `path`, or says why it cannot: a file
/// that exists by then is never replaced. A file it created but could not
/// fill is removed.
async fn write_new(path : String, bytes : Bytes) -> Result[Unit, String] {
  @fs.write_file(path, bytes, create_mode=CreateNew) catch {
    @os_error.OSError(_) as err if err.is_EEXIST() =>
      return Err("it exists now, and is not replaced")
    @os_error.OSError(_) as err if err.is_ENOENT() =>
      return Err("its directory does not exist")
    err => {
      @fs.remove(path) catch {
        _ => ()
      }
      return Err(@server.read_failure(err))
    }
  }
  Ok(())
}
