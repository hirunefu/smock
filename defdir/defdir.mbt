///|
/// Reads the definitions directory `dir`, if any, and validates it into a
/// snapshot, or returns every problem: those reading the directory, then
/// those in the definition set. `smock serve` and `smock check` both load
/// definitions this way, so a set that one accepts, the other accepts too.
/// Templates may read the environment variables `env`.
///
/// Without a directory, the definition set is empty.
pub async fn load(
  dir : String?,
  body_file_dir~ : String,
  env~ : @template.Env,
) -> Result[@definitions.Snapshot, Array[@definitions.Diagnostic]] {
  let (set, read_problems) = match dir {
    Some(dir) => read(dir, body_file_dir~)
    None => ({ files: [], body_files: [], }, [])
  }
  @definitions.load(set, read_problems~, env~)
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
///   files, named relative to it. Symlinks are followed while they stay
///   inside it: a file or a directory that one leads outside is a problem.
/// - A missing directory gives an empty definition set.
///
/// Problems reading the directory come back as diagnostics. A problem with
/// `dir` itself names it as given; a problem with a file or a directory in
/// it names that relative to `dir`.
pub async fn read(
  dir : String,
  body_file_dir~ : String,
) -> (@definitions.DefinitionSet, Array[@definitions.Diagnostic]) {
  let reader : DirReader = { root: dir, diagnostics: [], stamp: None, }
  let set = reader.read(body_file_dir~)
  (set, reader.diagnostics)
}

///|
/// Notes in `stamp` what `read` would read from the definitions directory
/// `dir`, without reading any file: whether the directory exists, the names
/// it would list, the kind of each entry it would look at, where each body
/// file really is, the times of each file it would read and the problems it
/// would report. So a poll can tell, from the stamp alone, that a read
/// would give the same definition set and the same problems.
pub async fn stamp(
  stamp : @watch.Stamp,
  dir : String,
  body_file_dir~ : String,
) -> Unit {
  let reader : DirReader = { root: dir, diagnostics: [], stamp: Some(stamp), }
  let _ = reader.read(body_file_dir~)
  for diagnostic in reader.diagnostics {
    stamp.note("problem \{diagnostic.file}: \{diagnostic.message}")
  }
}

///|
/// Reading one definitions directory: the directory, as given, and the
/// problems found so far. Every path it takes is relative to the
/// directory, and `""` is the directory itself.
///
/// While it takes a stamp instead, it notes in it what it finds, and the
/// times of each file in place of reading it.
priv struct DirReader {
  root : String
  diagnostics : Array[@definitions.Diagnostic]
  stamp : @watch.Stamp?
}

///|
/// Reads the directory into a definition set, as `read` describes, or,
/// while taking a stamp, an empty one.
async fn DirReader::read(
  self : DirReader,
  body_file_dir~ : String,
) -> @definitions.DefinitionSet {
  let set : @definitions.DefinitionSet = { files: [], body_files: [], }
  let exists = @fs.exists(self.root) catch {
    err => {
      self.problem("", "cannot be read: \{err}")
      return set
    }
  }
  if !exists {
    self.note("missing")
    return set
  }
  if self.kind("") is Some(kind) && !(kind is Directory) {
    self.problem("", "the definitions directory is not a directory")
    return set
  }
  for name in self.visible_entries("") {
    if !(name.has_suffix(".json") ||
      name.has_suffix(".yaml") ||
      name.has_suffix(".yml")) {
      continue
    }
    if self.kind(name) is Some(Regular) && self.read_file(name) is Some(bytes) {
      set.files.push((name, bytes))
    }
  }
  if self.kind(body_file_dir) is Some(Directory) {
    self.read_body_files(
      body_file_dir,
      set.body_files,
      base=body_file_dir,
      inside=None,
      visited=[],
    )
  }
  set
}

///|
/// Notes `note` in the stamp, while taking one.
fn DirReader::note(self : DirReader, note : String) -> Unit {
  if self.stamp is Some(stamp) {
    stamp.note(note)
  }
}

///|
/// The path of `relative` on the file system.
fn DirReader::path(self : DirReader, relative : String) -> String {
  if relative == "" {
    self.root
  } else {
    "\{self.root}/\{relative}"
  }
}

///|
/// Reports a problem with `relative`, named relative to the directory, or
/// as given when it is the directory itself.
fn DirReader::problem(
  self : DirReader,
  relative : String,
  message : String,
) -> Unit {
  self.diagnostics.push({
    file: if relative == "" {
      self.root
    } else {
      relative
    },
    pointer: "",
    message,
  })
}

///|
/// Reads the regular files under `relative` into `out`, recursively, named
/// relative to `base`, the body-file subdirectory. `inside` is where `base`
/// really is, once symlinks are resolved, or `None` when `relative` is
/// `base` itself. A file or a directory whose real path is not inside it
/// is reported instead: a symlink leads it outside `base`.
async fn DirReader::read_body_files(
  self : DirReader,
  relative : String,
  out : Array[(String, Bytes)],
  base~ : String,
  inside~ : String?,
  visited~ : Array[String],
) -> Unit {
  let real = self.realpath(relative)
  guard real is Some(real) else { return }
  let inside = inside.unwrap_or(real)
  if !self.stays_inside(relative, real~, inside~, base~) {
    return
  }
  // A symlink may lead back to a directory read already.
  if visited.contains(real) {
    return
  }
  visited.push(real)
  for name in self.visible_entries(relative) {
    let path = if relative == "" { name } else { "\{relative}/\{name}" }
    match self.kind(path) {
      Some(Regular) => {
        guard self.realpath(path) is Some(real) else { continue }
        if self.stays_inside(path, real~, inside~, base~) &&
          self.read_file(path, real~) is Some(bytes) {
          out.push((path[base.length() + 1:].to_owned(), bytes))
        }
      }
      Some(Directory) =>
        self.read_body_files(path, out, base~, inside=Some(inside), visited~)
      _ => ()
    }
  }
}

///|
/// Whether `real`, the real path of `relative`, is `inside` or within it,
/// `inside` being the real path of the body-file subdirectory `base`.
/// Reports `relative` when it is not.
fn DirReader::stays_inside(
  self : DirReader,
  relative : String,
  real~ : String,
  inside~ : String,
  base~ : String,
) -> Bool {
  let prefix = if inside.has_suffix("/") { inside } else { "\{inside}/" }
  if real == inside || real.has_prefix(prefix) {
    return true
  }
  self.problem(
    relative,
    "leads outside the body-file subdirectory \{base}, which body files must stay inside",
  )
  false
}

///|
/// The names in `relative` that do not start with `.`, in byte-wise order.
async fn DirReader::visible_entries(
  self : DirReader,
  relative : String,
) -> Array[String] {
  let names = @fs.readdir(self.path(relative)) catch {
    err => {
      self.problem(relative, "cannot be read: \{err}")
      return []
    }
  }
  let visible = names.filter(name => !name.has_prefix("."))
  visible.sort_by((a, b) => @utf8.encode(a).lexical_compare(@utf8.encode(b)))
  self.note("\{self.path(relative)}: entries \{visible.join("/")}")
  visible
}

///|
/// The real path of `relative`, once symlinks are resolved, or `None` when
/// it cannot be resolved.
async fn DirReader::realpath(self : DirReader, relative : String) -> String? {
  try @fs.realpath(self.path(relative)) catch {
    _ => {
      self.note("\{self.path(relative)}: no real path")
      None
    }
  } noraise {
    real => {
      self.note("\{self.path(relative)}: real path \{real}")
      Some(real)
    }
  }
}

///|
/// The kind of the file at `relative`, following symlinks, or `None` when
/// it cannot be found, such as a symlink to a missing file.
async fn DirReader::kind(self : DirReader, relative : String) -> @fs.FileKind? {
  let kind = try @fs.kind(self.path(relative)) catch {
    _ => None
  } noraise {
    kind => Some(kind)
  }
  if self.stamp is Some(_) {
    let shown = match kind {
      Some(Regular) => "a file"
      Some(Directory) => "a directory"
      Some(_) => "something else"
      None => "missing"
    }
    self.note("\{self.path(relative)}: \{shown}")
  }
  kind
}

///|
/// The bytes of the file at `relative`, or `None` when it cannot be read.
/// While taking a stamp, notes its real path and times instead, and gives
/// `None`. `real` is its real path, when that was resolved already.
async fn DirReader::read_file(
  self : DirReader,
  relative : String,
  real? : String,
) -> Bytes? {
  if self.stamp is Some(stamp) {
    stamp.note_file(self.path(relative), real?)
    return None
  }
  try @fs.read_file(self.path(relative)).binary() catch {
    err => {
      self.problem(relative, "cannot be read: \{err}")
      None
    }
  } noraise {
    bytes => Some(bytes)
  }
}
