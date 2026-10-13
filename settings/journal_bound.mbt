// The Journal's byte bound. An explicit --journal-max-bytes or
// SMOCK_JOURNAL_MAX_BYTES always wins. Without one, the bound follows the
// memory limit of smock's cgroup: a quarter of it, at least 1 MiB and at
// most the default, 64 MiB. This package does no I/O: the native server
// reads the cgroup at startup and hands its limit to the rule here.

///|
/// The memory limit of smock's cgroup: what `memory.max` of the cgroup v2
/// that smock runs in holds.
pub(all) enum MemoryLimit {
  /// At most this many bytes.
  Limited(Int64)
  /// `max`: no limit.
  Unlimited
  /// The limit could not be read, for the reason given, such as a cgroup v1
  /// host or a `memory.max` that does not exist.
  Unknown(String)
} derive(Debug, Eq)

///|
/// The Journal's byte bound: the most bytes its entries take, as they count
/// them, and what chose it.
pub(all) struct JournalByteBound {
  max_bytes : Int
  source : JournalByteBoundSource
} derive(Debug, Eq)

///|
/// What chose the Journal's byte bound.
pub(all) enum JournalByteBoundSource {
  /// `--journal-max-bytes`.
  Flag
  /// `SMOCK_JOURNAL_MAX_BYTES`.
  Variable
  /// A quarter of this memory limit, in bytes.
  MemoryLimit(Int64)
  /// The minimum, 1 MiB, since a quarter of this memory limit, in bytes, is
  /// below it.
  Minimum(Int64)
  /// The default, 64 MiB: there is no memory limit, it cannot be read, or a
  /// quarter of it is 64 MiB or more.
  Default(MemoryLimit)
} derive(Debug, Eq)

///|
/// The smallest bound a memory limit gives: 1 MiB, so that a tiny limit
/// still records something. It holds about 28 entries with a full 16 KiB
/// request head and a 4 KiB body (about 36 KiB each, as entries count), and
/// about 650 of the benchmark's request mix (about 1.6 KB each).
let min_journal_byte_bound : Int = 1024 * 1024

///|
/// The Journal's byte bound without an explicit one: a quarter of `limit`,
/// rounded down, at least `min_journal_byte_bound` (1 MiB) and at most the
/// default, 64 MiB. Without a limit, or when it could not be read, the
/// default.
pub fn JournalByteBound::from_memory_limit(
  limit : MemoryLimit,
) -> JournalByteBound {
  let default = journal_defaults.max_bytes
  match limit {
    Limited(bytes) => {
      let quarter = bytes / 4L
      if quarter >= default.to_int64() {
        { max_bytes: default, source: Default(limit), }
      } else if quarter < min_journal_byte_bound.to_int64() {
        { max_bytes: min_journal_byte_bound, source: Minimum(bytes), }
      } else {
        { max_bytes: quarter.to_int(), source: MemoryLimit(bytes), }
      }
    }
    Unlimited | Unknown(_) => { max_bytes: default, source: Default(limit), }
  }
}

///|
/// The name of the source, as the startup log gives it: `flag`, `variable`,
/// `memoryLimit`, `minimum` or `default`.
pub fn JournalByteBoundSource::name(self : JournalByteBoundSource) -> String {
  match self {
    Flag => "flag"
    Variable => "variable"
    MemoryLimit(_) => "memoryLimit"
    Minimum(_) => "minimum"
    Default(_) => "default"
  }
}

///|
/// The fields of the startup log entry that names the bound: `maxBytes`,
/// `source` (see `JournalByteBoundSource::name`) and, when the bound comes
/// from the memory limit, `memoryLimit`, in bytes or `"max"`, or
/// `memoryLimitError`, why it could not be read.
pub fn JournalByteBound::log_fields(
  self : JournalByteBound,
) -> Map[String, Json] {
  let fields : Map[String, Json] = {
    "maxBytes": Json::number(self.max_bytes.to_double()),
    "source": Json::string(self.source.name()),
  }
  let limit = match self.source {
    Flag | Variable => None
    MemoryLimit(bytes) | Minimum(bytes) => Some(Limited(bytes))
    Default(limit) => Some(limit)
  }
  match limit {
    None => ()
    Some(Limited(bytes)) =>
      fields["memoryLimit"] = Json::number(
        bytes.to_double(),
        repr=bytes.to_string(),
      )
    Some(Unlimited) => fields["memoryLimit"] = Json::string("max")
    Some(Unknown(reason)) => fields["memoryLimitError"] = Json::string(reason)
  }
  fields
}

///|
/// Where cgroup v2 is mounted: the unified hierarchy, as systemd and
/// Kubernetes nodes mount it.
let cgroup_root : String = "/sys/fs/cgroup"

///|
/// The `memory.max` file of the cgroup v2 that `proc_self_cgroup`, the text
/// of `/proc/self/cgroup`, names in its `0::<path>` line, under
/// `/sys/fs/cgroup`. `None` when it names none, as on a cgroup v1 host.
pub fn memory_max_file(proc_self_cgroup : String) -> String? {
  for line in proc_self_cgroup.split("\n") {
    if line.strip_prefix("0::") is Some(path) {
      let dir = if path == "/" { "" } else { path.to_owned() }
      return Some("\{cgroup_root}\{dir}/memory.max")
    }
  }
  None
}

///|
/// The memory limit `text`, what a `memory.max` file holds, gives: a
/// decimal number of bytes, or `max` for none, followed by a newline.
/// `None` when it is neither.
pub fn MemoryLimit::parse(text : String) -> MemoryLimit? {
  let value = text.trim_end(chars="\n").to_owned()
  if value == "max" {
    return Some(Unlimited)
  }
  // Nineteen digits hold every Int64, and more.
  match decimal(value, max_digits=19) {
    Some(bytes) if bytes <= 0x7fffffffffffffffUL =>
      Some(Limited(bytes.reinterpret_as_int64()))
    _ => None
  }
}
