// What smock's process and its cgroup use of CPU and memory, as Linux
// reports it: the formats of /proc/self/stat, /proc/self/status and
// /proc/self/cgroup, and of cpu.stat and memory.peak of a cgroup v2. This
// package does no I/O: the native server reads the files and hands their
// text here, so the formats are tested on every target.

///|
/// The clock ticks a second of the CPU times in `/proc/<pid>/stat`:
/// USER_HZ, which Linux fixes at 100 on x86-64 and arm64 whatever the
/// kernel's own tick rate, as Prometheus's client libraries take it too.
let user_hz : Double = 100

///|
/// The CPU time the process has used, user and system together, in
/// seconds: fields 14 (`utime`) and 15 (`stime`) of `proc_stat`, the text of
/// `/proc/<pid>/stat`, in clock ticks of 1/100 s, so to the hundredth of a
/// second. `None` when it is not such a line.
pub fn cpu_seconds(proc_stat : String) -> Double? {
  // The second field, the command name in parentheses, may hold spaces and
  // parentheses itself: the fields after it start after the last `)`, with
  // field 3, the state.
  guard proc_stat.rev_find(")") is Some(end) else { return None }
  let fields = proc_stat[end + 1:].trim().split(" ").collect()
  guard fields.length() > 12 &&
    decimal(fields[14 - 3]) is Some(utime) &&
    decimal(fields[15 - 3]) is Some(stime) else {
    return None
  }
  Some((utime + stime).to_double() / user_hz)
}

///|
/// The process's resident set size, in bytes: the `VmRSS` line of
/// `proc_status`, the text of `/proc/<pid>/status`, in KiB. `None` without
/// one.
pub fn resident_bytes(proc_status : String) -> Int64? {
  for line in proc_status.split("\n") {
    guard line.strip_prefix("VmRSS:") is Some(rest) else { continue }
    guard rest.trim().strip_suffix(" kB") is Some(kib) &&
      decimal(kib.trim()) is Some(kib) &&
      kib <= 0x7fffffffffffffffL / 1024L else {
      return None
    }
    return Some(kib * 1024L)
  }
  None
}

///|
/// Where cgroup v2 is mounted: the unified hierarchy, as systemd and
/// Kubernetes nodes mount it.
let cgroup_root : String = "/sys/fs/cgroup"

///|
/// The directory of the cgroup v2 that `proc_self_cgroup`, the text of
/// `/proc/self/cgroup`, names in its `0::<path>` line, under
/// `/sys/fs/cgroup`: `/sys/fs/cgroup` itself for a container in its own
/// cgroup namespace, as in Kubernetes. `None` when it names none, as on a
/// cgroup v1 host.
pub fn cgroup_dir(proc_self_cgroup : String) -> String? {
  for line in proc_self_cgroup.split("\n") {
    if line.strip_prefix("0::") is Some(path) {
      let dir = if path == "/" { "" } else { path.to_owned() }
      return Some("\{cgroup_root}\{dir}")
    }
  }
  None
}

///|
/// What a cgroup's `cpu.stat` says of its CPU use. A count is `None` when
/// the file does not have it: the CFS ones (`nr_periods`, `nr_throttled`,
/// `throttled_usec`) are there only when the cgroup's cpu controller is
/// enabled, which it is for a container with a CPU limit.
pub(all) struct CpuStat {
  /// `usage_usec`: the CPU time the cgroup's processes used, in
  /// microseconds.
  usage_usec : Int64?
  /// `nr_periods`: the CFS periods that have elapsed while the cgroup had
  /// something to run.
  nr_periods : Int64?
  /// `nr_throttled`: the periods in which the cgroup used up its CPU quota.
  nr_throttled : Int64?
  /// `throttled_usec`: how long the CPU quota held the cgroup back, in
  /// microseconds.
  throttled_usec : Int64?
} derive(Debug, Eq)

///|
/// The counts in `text`, what a cgroup v2 `cpu.stat` file holds: a
/// `<key> <value>` line each. Lines that are not one, and the keys this
/// does not read, are left out.
pub fn CpuStat::parse(text : String) -> CpuStat {
  let mut usage_usec = None
  let mut nr_periods = None
  let mut nr_throttled = None
  let mut throttled_usec = None
  for line in text.split("\n") {
    guard line.split_once(" ") is Some((key, value)) &&
      decimal(value) is Some(count) else {
      continue
    }
    match key {
      "usage_usec" => usage_usec = Some(count)
      "nr_periods" => nr_periods = Some(count)
      "nr_throttled" => nr_throttled = Some(count)
      "throttled_usec" => throttled_usec = Some(count)
      _ => ()
    }
  }
  { usage_usec, nr_periods, nr_throttled, throttled_usec, }
}

///|
/// The most memory a cgroup has used, in bytes: `text`, what a cgroup v2
/// `memory.peak` file holds, a number of bytes and a newline. `None` when it
/// is not one.
pub fn memory_peak(text : String) -> Int64? {
  decimal(text.trim_end(chars="\n"))
}

///|
/// The number `text` writes in decimal digits, when it is one an `Int64`
/// holds: at most 19 digits, and no sign.
fn decimal(text : StringView) -> Int64? {
  if text.length() == 0 || text.length() > 19 {
    return None
  }
  let mut n = 0UL
  for c in text {
    guard c >= '0' && c <= '9' else { return None }
    n = n * 10UL + (c.to_int() - '0'.to_int()).to_uint64()
  }
  if n > 0x7fffffffffffffffUL {
    None
  } else {
    Some(n.reinterpret_as_int64())
  }
}
