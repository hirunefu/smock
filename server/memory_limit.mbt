// The memory limit of smock's cgroup, which `serve` reads once at startup
// when the Journal's byte bound or the per-Session state's is not set, and
// the bounds it gives (`@settings.ByteBound::journal` and
// `@settings.ByteBound::state`). The rules and the file formats live in the
// settings package, which does no I/O; only the reading is here.

///|
/// The file that names the cgroups of the process.
let proc_self_cgroup : String = "/proc/self/cgroup"

///|
/// Reads the memory limit of the cgroup v2 that smock runs in: `memory.max`
/// of the cgroup that `/proc/self/cgroup` names, under `/sys/fs/cgroup`.
/// It is `Unknown`, with the reason, when either file cannot be read, when
/// there is no cgroup v2 or when `memory.max` holds neither a number nor
/// `max`.
async fn read_memory_limit() -> @settings.MemoryLimit {
  let cgroups = @fs.read_file(proc_self_cgroup).text() catch {
    err =>
      return Unknown("cannot read \{proc_self_cgroup}: \{read_failure(err)}")
  }
  guard @settings.memory_max_file(cgroups) is Some(file) else {
    return Unknown("\{proc_self_cgroup} names no cgroup v2")
  }
  let text = @fs.read_file(file).text() catch {
    err => return Unknown("cannot read \{file}: \{read_failure(err)}")
  }
  match @settings.MemoryLimit::parse(text) {
    Some(limit) => limit
    None =>
      Unknown(
        "\{file} holds \{text.escape()}, neither a number of bytes nor max",
      )
  }
}

///|
/// The byte bounds that follow the memory limit: the Journal's and the
/// per-Session state's, each the one `settings` sets, or else the one the
/// memory limit of smock's cgroup gives. The limit is read once, now, for
/// both, and only when one of them needs it.
async fn byte_bounds(settings : @settings.ServeSettings) -> ByteBounds {
  let mut limit : @settings.MemoryLimit? = None
  let journal = match settings.journal_max_bytes {
    Some(bound) => bound
    None => {
      let read = read_memory_limit()
      limit = Some(read)
      @settings.ByteBound::journal(read)
    }
  }
  let state = match settings.state_max_bytes {
    Some(bound) => bound
    None =>
      @settings.ByteBound::state(
        match limit {
          Some(read) => read
          None => read_memory_limit()
        },
      )
  }
  { journal, state, }
}

///|
/// The byte bounds `serve` starts with.
priv struct ByteBounds {
  /// The Journal's.
  journal : @settings.ByteBound
  /// The per-Session state's.
  state : @settings.ByteBound
}
