///|
/// Reads the definitions directory `dir`, if any, and validates it into a
/// snapshot, or returns every problem: those reading the directory, then
/// those in the definition set. `smock serve` and `smock check` both load
/// definitions this way, so a set that one accepts, the other accepts too.
///
/// Without a directory, the definition set is empty.
pub async fn load(
  dir : String?,
  body_file_dir~ : String,
) -> Result[@definitions.Snapshot, Array[@definitions.Diagnostic]] {
  let (set, read_problems) = match dir {
    Some(dir) => read(dir, body_file_dir~)
    None => ({ files: [], body_files: [], }, [])
  }
  @definitions.load(set, read_problems~)
}

///|
/// Reads the definitions directory `dir` into a definition set.
///
/// - Definition files are the regular files at the top level whose names
///   end in `.yaml`, `.yml` or `.json`. Symlinks are followed.
/// - Entries whose names start with `.` are skipped, at every level. This
///   covers the `..data` entries of ConfigMap volumes.
/// - Files come in byte-wise name order.
/// - The files under `body_file_dir`, a subdirectory of `dir`, are the body
///   files, named relative to it.
/// - A missing directory gives an empty definition set.
///
/// Problems reading the directory come back as diagnostics, with the file
/// named relative to `dir`.
pub async fn read(
  dir : String,
  body_file_dir~ : String,
) -> (@definitions.DefinitionSet, Array[@definitions.Diagnostic]) {
  let diagnostics : Array[@definitions.Diagnostic] = []
  let set : @definitions.DefinitionSet = { files: [], body_files: [], }
  let exists = @fs.exists(dir) catch {
    err => {
      diagnostics.push({
        file: dir,
        pointer: "",
        message: "cannot be read: \{err}",
      })
      return (set, diagnostics)
    }
  }
  if !exists {
    return (set, diagnostics)
  }
  if kind(dir) is Some(kind) && !(kind is Directory) {
    diagnostics.push({
      file: dir,
      pointer: "",
      message: "the definitions directory is not a directory",
    })
    return (set, diagnostics)
  }
  for name in visible_entries(dir, "", diagnostics) {
    if !(name.has_suffix(".json") ||
      name.has_suffix(".yaml") ||
      name.has_suffix(".yml")) {
      continue
    }
    if kind("\{dir}/\{name}") is Some(Regular) &&
      read_file(dir, name, diagnostics) is Some(bytes) {
      set.files.push((name, bytes))
    }
  }
  if kind("\{dir}/\{body_file_dir}") is Some(Directory) {
    read_body_files(
      dir,
      body_file_dir,
      set.body_files,
      diagnostics,
      base=body_file_dir,
      visited=[],
    )
  }
  (set, diagnostics)
}

///|
/// Reads the regular files under `root/relative` into `out`, recursively,
/// named relative to `root/base`. Problems name files relative to `root`.
async fn read_body_files(
  root : String,
  relative : String,
  out : Array[(String, Bytes)],
  diagnostics : Array[@definitions.Diagnostic],
  base~ : String,
  visited~ : Array[String],
) -> Unit {
  let dir = if relative == "" { root } else { "\{root}/\{relative}" }
  // A symlink may lead back to a directory read already.
  let real = @fs.realpath(dir) catch { _ => return }
  if visited.contains(real) {
    return
  }
  visited.push(real)
  for name in visible_entries(root, relative, diagnostics) {
    let path = if relative == "" { name } else { "\{relative}/\{name}" }
    match kind("\{root}/\{path}") {
      Some(Regular) =>
        if read_file(root, path, diagnostics) is Some(bytes) {
          out.push((path[base.length() + 1:].to_owned(), bytes))
        }
      Some(Directory) =>
        read_body_files(root, path, out, diagnostics, base~, visited~)
      _ => ()
    }
  }
}

///|
/// The names in `root/relative` that do not start with `.`, in byte-wise
/// order.
async fn visible_entries(
  root : String,
  relative : String,
  diagnostics : Array[@definitions.Diagnostic],
) -> Array[String] {
  let dir = if relative == "" { root } else { "\{root}/\{relative}" }
  let names = @fs.readdir(dir) catch {
    err => {
      diagnostics.push({
        file: if relative == "" {
          "."
        } else {
          relative
        },
        pointer: "",
        message: "cannot be read: \{err}",
      })
      return []
    }
  }
  let visible = names.filter(name => !name.has_prefix("."))
  visible.sort_by((a, b) => @utf8.encode(a).lexical_compare(@utf8.encode(b)))
  visible
}

///|
/// The kind of the file at `path`, following symlinks, or `None` when it
/// cannot be found, such as a symlink to a missing file.
async fn kind(path : String) -> @fs.FileKind? {
  try @fs.kind(path) catch {
    _ => None
  } noraise {
    kind => Some(kind)
  }
}

///|
async fn read_file(
  root : String,
  path : String,
  diagnostics : Array[@definitions.Diagnostic],
) -> Bytes? {
  try @fs.read_file("\{root}/\{path}").binary() catch {
    err => {
      diagnostics.push({
        file: path,
        pointer: "",
        message: "cannot be read: \{err}",
      })
      None
    }
  } noraise {
    bytes => Some(bytes)
  }
}
