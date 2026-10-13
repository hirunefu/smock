// The memory limit of smock's cgroup, which `serve` reads at startup when no
// Journal byte bound is set, and the bound it gives
// (`@settings.JournalByteBound::from_memory_limit`). The rule and the file
// formats live in the settings package, which does no I/O; only the reading
// is here.

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
/// The Journal's byte bound: the one `settings` sets, or else the one the
/// memory limit of smock's cgroup gives, which it reads now.
async fn journal_byte_bound(
  settings : @settings.ServeSettings,
) -> @settings.JournalByteBound {
  match settings.journal_max_bytes {
    Some(bound) => bound
    None => @settings.JournalByteBound::from_memory_limit(read_memory_limit())
  }
}
