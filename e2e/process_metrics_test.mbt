// Seam 2 tests of the process metrics, of smock's scheduling metrics and
// of the metrics of smock's cgroup on /metrics. Each is read when /metrics
// is scraped: the tests read the same files themselves, apart from smock's
// reader, right before and right after a scrape, and check that what
// /metrics says lies between the two.

///|
/// The CPU time process `pid` has used, user and system, in clock ticks of
/// 1/100 s: fields 14 and 15 of /proc/<pid>/stat, counted from field 3,
/// the first after the command name in parentheses.
async fn cpu_ticks(pid : Int) -> Int {
  let text = @fs.read_file("/proc/\{pid}/stat").text()
  guard text.rev_find(")") is Some(end) else { fail("no ) in \{text}") }
  let fields = text[end + 2:].split(" ").collect()
  @string.parse_int(fields[14 - 3]) + @string.parse_int(fields[15 - 3])
}

///|
/// The resident set size of process `pid`, in bytes: VmRSS of
/// /proc/<pid>/status, in KiB.
async fn resident_set(pid : Int) -> Double {
  for line in @fs.read_file("/proc/\{pid}/status").text().split("\n") {
    if line.strip_prefix("VmRSS:") is Some(rest) &&
      rest.trim().strip_suffix(" kB") is Some(kib) {
      return @string.parse_double(kib.trim()) * 1024.0
    }
  }
  fail("no VmRSS in /proc/\{pid}/status")
}

///|
/// The directory of the cgroup v2 of process `pid`, from the `0::` line of
/// /proc/<pid>/cgroup.
async fn cgroup_of(pid : Int) -> String {
  for line in @fs.read_file("/proc/\{pid}/cgroup").text().split("\n") {
    if line.strip_prefix("0::") is Some(path) {
      return if path == "/" {
        "/sys/fs/cgroup"
      } else {
        "/sys/fs/cgroup\{path}"
      }
    }
  }
  fail("process \{pid} is in no cgroup v2")
}

///|
/// The counts of the cgroup `dir`'s cpu.stat, by key.
async fn cgroup_cpu_stat(dir : String) -> Map[String, Double] {
  let stat = Map([])
  for line in @fs.read_file("\{dir}/cpu.stat").text().split("\n") {
    if line.split_once(" ") is Some((key, value)) {
      stat[key.to_owned()] = @string.parse_double(value)
    }
  }
  stat
}

///|
/// The memory peak of the cgroup `dir`, from its memory.peak, or `None`
/// when it has none.
async fn cgroup_memory_peak(dir : String) -> Double? {
  let text = @fs.read_file("\{dir}/memory.peak").text() catch {
    _ => return None
  }
  Some(@string.parse_double(text.trim()))
}

///|
/// Sends smock requests on one connection, 50 at a time, until `done`
/// says that what they were for (`what`) has happened.
async fn work_until(
  smock : Smock,
  what : String,
  done : async () -> Bool,
) -> Unit {
  let conn = smock.connect()
  defer conn.close()
  let worked = @async.with_timeout_opt(patience_ms, () => {
    while !done() {
      for _ in 0..<50 {
        conn.write(raw_request("GET", "/", host="localhost"))
        let _ = read_response(conn)
      }
    }
  })
  guard worked is Some(_) else {
    fail("requests to smock did not bring \{what} in time")
  }
}

///|
/// The `# HELP` and `# TYPE` lines of the metrics in `/metrics`, `text`,
/// whose names start with `prefix`.
fn about_lines(text : String, prefix : String) -> String {
  metric_lines(text, prefix, help=true)
  .filter(line => line.has_prefix("#"))
  .join("\n")
}

///|
/// Whether `value` lies between `low` and `high`, both included.
fn between(value : Double, low : Double, high : Double) -> Bool {
  low <= value && value <= high
}

///|
async test "process metrics: smock's CPU time and RSS as /proc has them when /metrics is scraped, and when it started" {
  let before_start = @async.now().to_double() / 1000.0
  let _ = with_smock(["--port", "0"], smock => {
    let listening = @async.now().to_double() / 1000.0
    // Until the kernel has counted some CPU time for smock, so that a value
    // read when smock started would be below it.
    work_until(smock, "3 ticks of CPU time", () => cpu_ticks(smock.pid) >= 3)
    let ticks = cpu_ticks(smock.pid)
    let resident = resident_set(smock.pid)
    let text = smock.admin("GET", "/metrics", token=None).body
    let ticks_after = cpu_ticks(smock.pid)
    let resident_after = resident_set(smock.pid)
    let _ = parse_prometheus(text)
    let cpu = metric_value(text, "process_cpu_seconds_total")
    let rss = metric_value(text, "process_resident_memory_bytes")
    let start = metric_value(text, "process_start_time_seconds")
    // The scrape itself may take or give back a page or two.
    let slack = 1024.0 * 1024.0
    let (low, high) = if resident <= resident_after {
      (resident, resident_after)
    } else {
      (resident_after, resident)
    }
    inspect(
      [
        about_lines(text, "process_"),
        "CPU time as /proc had it at the scrape: \{between(cpu, ticks.to_double() / 100.0, ticks_after.to_double() / 100.0)}",
        "RSS as /proc had it at the scrape: \{between(rss, low - slack, high + slack)}",
        "started between the test starting it and its listening: \{between(start, before_start, listening)}",
      ].join("\n"),
      content=(
        #|# HELP process_start_time_seconds When the smock process started, in seconds since the Unix epoch. It changes when the process restarts.
        #|# TYPE process_start_time_seconds gauge
        #|# HELP process_cpu_seconds_total CPU time the smock process has used, user and system, in seconds, to the hundredth of a second (utime and stime of /proc/self/stat).
        #|# TYPE process_cpu_seconds_total counter
        #|# HELP process_resident_memory_bytes The smock process's resident set size, in bytes (VmRSS of /proc/self/status).
        #|# TYPE process_resident_memory_bytes gauge
        #|CPU time as /proc had it at the scrape: true
        #|RSS as /proc had it at the scrape: true
        #|started between the test starting it and its listening: true
      ),
    )
  })
}

///|
/// How long the main thread of process `pid` waited for a CPU, in
/// nanoseconds: run_delay, the second field of /proc/<pid>/schedstat.
async fn run_delay_ns(pid : Int) -> Double {
  let text = @fs.read_file("/proc/\{pid}/schedstat").text()
  let fields = text.trim(chars="\n").split(" ").collect()
  guard fields.length() >= 2 else { fail("no run_delay in \{text}") }
  @string.parse_double(fields[1])
}

///|
/// How many times the kernel took the CPU from the main thread of process
/// `pid` while it could still run: nonvoluntary_ctxt_switches of
/// /proc/<pid>/status.
async fn involuntary_switches(pid : Int) -> Double {
  for line in @fs.read_file("/proc/\{pid}/status").text().split("\n") {
    if line.strip_prefix("nonvoluntary_ctxt_switches:") is Some(rest) {
      return @string.parse_double(rest.trim())
    }
  }
  fail("no nonvoluntary_ctxt_switches in /proc/\{pid}/status")
}

///|
/// The machine's steal time, in clock ticks of 1/100 s: the eighth count
/// of the cpu line of /proc/stat.
async fn steal_ticks() -> Double {
  for line in @fs.read_file("/proc/stat").text().split("\n") {
    if line.strip_prefix("cpu ") is Some(rest) {
      let counts = rest.trim().split(" ").collect()
      guard counts.length() >= 8 else { fail("no steal in \{line}") }
      return @string.parse_double(counts[7])
    }
  }
  fail("no cpu line in /proc/stat")
}

///|
async test "scheduling metrics: smock's scheduling delay and involuntary context switches, and the machine's steal time, as /proc has them when /metrics is scraped" {
  let _ = with_smock(["--port", "0"], smock => {
    work_until(smock, "3 ticks of CPU time", () => cpu_ticks(smock.pid) >= 3)
    let delay = run_delay_ns(smock.pid)
    let switches = involuntary_switches(smock.pid)
    let steal = steal_ticks()
    let text = smock.admin("GET", "/metrics", token=None).body
    let delay_after = run_delay_ns(smock.pid)
    let switches_after = involuntary_switches(smock.pid)
    let steal_after = steal_ticks()
    let _ = parse_prometheus(text)
    let delay_s = metric_value(
      text, "smock_process_scheduling_delay_seconds_total",
    )
    let switched = metric_value(
      text, "smock_process_involuntary_context_switches_total",
    )
    let stolen = metric_value(text, "smock_node_cpu_steal_seconds_total")
    inspect(
      [
        about_lines(text, "smock_process_"),
        about_lines(text, "smock_node_"),
        "scheduling delay as /proc had it at the scrape: \{between(delay_s, delay / 1.0e9, delay_after / 1.0e9)}",
        "involuntary context switches as /proc had them at the scrape: \{between(switched, switches, switches_after)}",
        "steal time as /proc had it at the scrape: \{between(stolen, steal / 100.0, steal_after / 100.0)}",
      ].join("\n"),
      content=(
        #|# HELP smock_process_scheduling_delay_seconds_total How long smock's main thread, which serves every request, was ready to run but waited for a CPU, in seconds, to the nanosecond (run_delay of /proc/self/schedstat).
        #|# TYPE smock_process_scheduling_delay_seconds_total counter
        #|# HELP smock_process_involuntary_context_switches_total Times the kernel took the CPU from smock's main thread, which serves every request, while it could still run (nonvoluntary_ctxt_switches of /proc/self/status).
        #|# TYPE smock_process_involuntary_context_switches_total counter
        #|# HELP smock_node_cpu_steal_seconds_total CPU time the hypervisor gave to something else while the CPUs of the machine smock runs on, all of them together, had something to run, in seconds, to the hundredth of a second (steal of the cpu line of /proc/stat): the machine's, not smock's, and 0 on bare metal.
        #|# TYPE smock_node_cpu_steal_seconds_total counter
        #|scheduling delay as /proc had it at the scrape: true
        #|involuntary context switches as /proc had them at the scrape: true
        #|steal time as /proc had it at the scrape: true
      ),
    )
  })
}

///|
/// The command that runs the command after it in a new systemd user scope
/// with a CPU quota of half a CPU and the memory limit `scope_memory_max`,
/// as bench/bench.py runs smock under a profile. It becomes that command by
/// exec, so the command keeps its process ID.
let quota_scope : Array[String] = [
  "systemd-run",
  "--user",
  "--scope",
  "--quiet",
  "--collect",
  "-p",
  "CPUQuota=50%",
  "-p",
  "MemoryMax=\{scope_memory_max}",
  "--",
]

///|
/// Why smock cannot run in a scope with a CPU quota here, or `None` when it
/// can: a shell run as `quota_scope` prints its own cgroup's cpu.max, which
/// must be the scope's quota.
async fn quota_scope_unavailable() -> String? {
  let script = "cat \"/sys/fs/cgroup$(sed -n 's/^0:://p' /proc/self/cgroup)/cpu.max\""
  let command = [..quota_scope, "sh", "-c", script]
  let (status, output) = @process.collect_output_merged(
    command[0],
    command[1:].to_owned(),
  ) catch {
    err => return Some("systemd-run cannot be run: \{err}")
  }
  let text = output.text().trim(chars="\n").to_owned()
  if status != 0 {
    Some("systemd-run --user failed with exit status \{status}: \{text}")
  } else if text != "50000 100000" {
    Some(
      "a scope with CPUQuota=50% got cpu.max \{text.escape()}: the systemd user manager needs the cpu controller delegated to it (see the README's benchmark section)",
    )
  } else {
    None
  }
}

///|
/// What `/metrics`, `text`, says of the cgroup `dir` against its files
/// read right before (`stat`, `peak`) and right after (`stat_after`,
/// `peak_after`) the scrape: for each count of its cpu.stat this reads, and
/// for its memory.peak, whether /metrics has it, and when both do, whether
/// /metrics has a value between the two readings.
fn cgroup_report(
  text : String,
  stat : Map[String, Double],
  stat_after : Map[String, Double],
  peak : Double?,
  peak_after : Double?,
) -> String raise {
  let samples = parse_prometheus(text)
  let value = (name : String) => {
    samples.iter().find_first(sample => sample.name == name).map(s => s.value)
  }
  let out = []
  let report = (
    name : String,
    file : String,
    low : Double?,
    high : Double?,
    unit : Double,
  ) => {
    let line = match (value(name), low, high) {
      (None, None, _) => "neither in the file nor in /metrics"
      (Some(_), None, _) => "in /metrics only"
      (None, Some(_), _) => "in the file only"
      (Some(v), Some(low), Some(high)) =>
        "as the file had it at the scrape: \{between(v, low / unit, high / unit)}"
      (Some(_), Some(_), None) => "gone from the file after the scrape"
    }
    out.push("\{name} (\{file}): \{line}")
  }
  report(
    "smock_cgroup_cpu_usage_seconds_total",
    "usage_usec",
    stat.get("usage_usec"),
    stat_after.get("usage_usec"),
    1.0e6,
  )
  report(
    "smock_cgroup_cpu_periods_total",
    "nr_periods",
    stat.get("nr_periods"),
    stat_after.get("nr_periods"),
    1.0,
  )
  report(
    "smock_cgroup_cpu_throttled_periods_total",
    "nr_throttled",
    stat.get("nr_throttled"),
    stat_after.get("nr_throttled"),
    1.0,
  )
  report(
    "smock_cgroup_cpu_throttled_seconds_total",
    "throttled_usec",
    stat.get("throttled_usec"),
    stat_after.get("throttled_usec"),
    1.0e6,
  )
  report("smock_cgroup_memory_peak_bytes", "memory.peak", peak, peak_after, 1.0)
  out.join("\n")
}

///|
async test "cgroup metrics: under a CPU quota and a memory limit, smock's cgroup's CPU usage, CFS periods, throttling and memory peak as its files have them when /metrics is scraped" {
  if quota_scope_unavailable() is Some(reason) {
    println(
      "skipped \"cgroup metrics: under a CPU quota\" (e2e/process_metrics_test.mbt): it runs smock in a systemd user scope with a CPU quota, but \{reason}",
    )
    return
  }
  let _ = with_smock(
    ["--port", "0"],
    env=user_manager_env({}),
    under=quota_scope,
    smock => {
      let dir = cgroup_of(smock.pid)
      // Until the kernel has counted some CPU time for smock, and a CFS
      // period has ended since it started: the first one ends 100 ms
      // after smock first ran.
      work_until(smock, "a CFS period", () => {
        cpu_ticks(smock.pid) >= 3 &&
        cgroup_cpu_stat(dir).get("nr_periods").unwrap_or(0) > 0
      })
      let stat = cgroup_cpu_stat(dir)
      let peak = cgroup_memory_peak(dir)
      let text = smock.admin("GET", "/metrics", token=None).body
      let stat_after = cgroup_cpu_stat(dir)
      let peak_after = cgroup_memory_peak(dir)
      inspect(
        [
          about_lines(text, "smock_cgroup_"),
          cgroup_report(text, stat, stat_after, peak, peak_after),
          "CFS periods counted: \{stat.get("nr_periods").unwrap_or(0) > 0}",
        ].join("\n"),
        content=(
          #|# HELP smock_cgroup_cpu_usage_seconds_total CPU time smock's cgroup has used, in seconds, to the microsecond (usage_usec of its cpu.stat): smock's, and that of any other process in the cgroup.
          #|# TYPE smock_cgroup_cpu_usage_seconds_total counter
          #|# HELP smock_cgroup_cpu_periods_total CFS periods that have elapsed while smock's cgroup had something to run, under its CPU quota (nr_periods of its cpu.stat). A CPU limit in Kubernetes has periods of 100 ms.
          #|# TYPE smock_cgroup_cpu_periods_total counter
          #|# HELP smock_cgroup_cpu_throttled_periods_total CFS periods in which smock's cgroup used up its CPU quota and was held back until the next one (nr_throttled of its cpu.stat).
          #|# TYPE smock_cgroup_cpu_throttled_periods_total counter
          #|# HELP smock_cgroup_cpu_throttled_seconds_total How long the CPU quota held smock's cgroup back, in seconds (throttled_usec of its cpu.stat).
          #|# TYPE smock_cgroup_cpu_throttled_seconds_total counter
          #|# HELP smock_cgroup_memory_peak_bytes The most memory smock's cgroup has used since it was made, in bytes (its memory.peak): all that its memory.max limits, socket buffers and page cache included.
          #|# TYPE smock_cgroup_memory_peak_bytes gauge
          #|smock_cgroup_cpu_usage_seconds_total (usage_usec): as the file had it at the scrape: true
          #|smock_cgroup_cpu_periods_total (nr_periods): as the file had it at the scrape: true
          #|smock_cgroup_cpu_throttled_periods_total (nr_throttled): as the file had it at the scrape: true
          #|smock_cgroup_cpu_throttled_seconds_total (throttled_usec): as the file had it at the scrape: true
          #|smock_cgroup_memory_peak_bytes (memory.peak): as the file had it at the scrape: true
          #|CFS periods counted: true
        ),
      )
    },
  )
}

///|
async test "cgroup metrics: in whatever cgroup smock runs, /metrics has a cgroup metric exactly when the cgroup's file has its count, as the file has it when /metrics is scraped" {
  let _ = with_smock(["--port", "0"], smock => {
    let dir = cgroup_of(smock.pid)
    let stat = cgroup_cpu_stat(dir)
    let peak = cgroup_memory_peak(dir)
    let text = smock.admin("GET", "/metrics", token=None).body
    let stat_after = cgroup_cpu_stat(dir)
    let peak_after = cgroup_memory_peak(dir)
    // Without the cpu controller, as in a cgroup with no CPU limit, the
    // file has no CFS counts, and /metrics has none either; without the
    // memory controller, no memory.peak.
    let lines = cgroup_report(text, stat, stat_after, peak, peak_after)
      .split("\n")
      .map(line => {
        match line.split_once(": ") {
          Some((name, "as the file had it at the scrape: true"))
          | Some((name, "neither in the file nor in /metrics")) => "\{name}: ok"
          _ => line.to_owned()
        }
      })
      .collect()
    inspect(
      lines.join("\n"),
      content=(
        #|smock_cgroup_cpu_usage_seconds_total (usage_usec): ok
        #|smock_cgroup_cpu_periods_total (nr_periods): ok
        #|smock_cgroup_cpu_throttled_periods_total (nr_throttled): ok
        #|smock_cgroup_cpu_throttled_seconds_total (throttled_usec): ok
        #|smock_cgroup_memory_peak_bytes (memory.peak): ok
      ),
    )
    // cpu.stat always has the usage.
    inspect(
      metric_lines(text, "smock_cgroup_cpu_usage_seconds_total ").length(),
      content="1",
    )
  })
}
