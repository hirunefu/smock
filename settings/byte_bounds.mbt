// The byte bounds that follow the memory limit (ADR 0004): the Journal's
// and the per-Session state's. An explicit setting, such as
// --journal-max-bytes or SMOCK_STATE_MAX_BYTES, always wins. Without one, a
// bound follows the memory limit of smock's cgroup: a quarter of it for the
// Journal, an eighth for per-Session state, at least 1 MiB and at most the
// default, 64 MiB. This package does no I/O: the native server reads the
// cgroup once at startup and hands its limit to the rules here.

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
/// A byte bound that follows the memory limit, the Journal's or the
/// per-Session state's: the most bytes it lets what it bounds count, and
/// what chose it.
pub(all) struct ByteBound {
  max_bytes : Int32
  source : ByteBoundSource
} derive(Debug, Eq)

///|
/// What chose a byte bound.
pub(all) enum ByteBoundSource {
  /// Its flag, such as `--journal-max-bytes`.
  Flag
  /// Its variable, such as `SMOCK_JOURNAL_MAX_BYTES`.
  Variable
  /// Its share of this memory limit, in bytes: a quarter for the Journal,
  /// an eighth for per-Session state.
  MemoryLimit(Int64)
  /// The minimum, 1 MiB, since its share of this memory limit, in bytes, is
  /// below it.
  Minimum(Int64)
  /// The default, 64 MiB: there is no memory limit, it cannot be read, or
  /// its share of it is 64 MiB or more.
  Default(MemoryLimit)
} derive(Debug, Eq)

///|
/// The smallest bound a memory limit gives: 1 MiB. For the Journal, it
/// keeps a tiny limit recording something: it holds about 28 entries with a
/// full 16 KiB request head and a 4 KiB body (about 36 KiB each, as entries
/// count), and about 650 of the benchmark's request mix (about 1.6 KB each).
let min_byte_bound : Int32 = 1024 * 1024

///|
/// The Journal's byte bound without an explicit one: a quarter of `limit`,
/// rounded down, at least `min_byte_bound` (1 MiB) and at most the default,
/// 64 MiB. Without a limit, or when it could not be read, the default.
pub fn ByteBound::journal(limit : MemoryLimit) -> ByteBound {
  share_of(limit, parts=4L, default=journal_defaults.max_bytes)
}

///|
/// The byte bound on per-Session state without an explicit one: an eighth
/// of `limit`, rounded down, at least `min_byte_bound` (1 MiB) and at most
/// the default, 64 MiB. Without a limit, or when it could not be read, the
/// default. With the Journal's quarter, five eighths of the limit are left
/// to what neither bound counts.
pub fn ByteBound::state(limit : MemoryLimit) -> ByteBound {
  share_of(limit, parts=8L, default=@engine.default_state_max_bytes)
}

///|
/// ADR 0004's rule: one of `parts` equal parts of `limit`, rounded down, at
/// least `min_byte_bound` and at most `default`. Without a limit, or when it
/// could not be read, `default`.
fn share_of(limit : MemoryLimit, parts~ : Int64, default~ : Int32) -> ByteBound {
  match limit {
    Limited(bytes) => {
      let share = bytes / parts
      if share >= default.to_int64() {
        { max_bytes: default, source: Default(limit), }
      } else if share < min_byte_bound.to_int64() {
        { max_bytes: min_byte_bound, source: Minimum(bytes), }
      } else {
        { max_bytes: share.to_int(), source: MemoryLimit(bytes), }
      }
    }
    Unlimited | Unknown(_) => { max_bytes: default, source: Default(limit), }
  }
}

///|
/// The name of the source, as the startup log gives it: `flag`, `variable`,
/// `memoryLimit`, `minimum` or `default`.
pub fn ByteBoundSource::name(self : ByteBoundSource) -> String {
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
/// `source` (see `ByteBoundSource::name`) and, when the bound comes
/// from the memory limit, `memoryLimit`, in bytes or `"max"`, or
/// `memoryLimitError`, why it could not be read.
pub fn ByteBound::log_fields(self : ByteBound) -> Map[String, Json] {
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
/// The `memory.max` file of the cgroup v2 that `proc_self_cgroup`, the text
/// of `/proc/self/cgroup`, names in its `0::<path>` line, under
/// `/sys/fs/cgroup` (`@usage.cgroup_dir`). `None` when it names none, as on
/// a cgroup v1 host.
pub fn memory_max_file(proc_self_cgroup : String) -> String? {
  @usage.cgroup_dir(proc_self_cgroup).map(dir => "\{dir}/memory.max")
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
