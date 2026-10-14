// The process metrics, which Prometheus's client libraries give every
// process, and the metrics of smock's cgroup: what smock's process and its
// cgroup use of CPU and memory, as Linux counts it. They are read from /proc
// and from the cgroup's files when /metrics is scraped, so serving requests
// costs nothing for them; a run on GKE Autopilot, where nothing outside
// the Pod reads its cgroup, measures smock with them. The file formats are
// in the usage package, which does no I/O; only the reading is here.

///|
/// The files the process and cgroup metrics are read from.
priv struct ProcessFiles {
  /// The process's status line, with its CPU times among others, as
  /// `/proc/self/stat` has it.
  stat : String
  /// The process's status, one field a line, with its resident set size
  /// among others, as `/proc/self/status` has it.
  status : String
  /// The directory of the process's cgroup v2, or `None` outside one.
  cgroup_dir : String?
}

///|
/// The files of this process: its own under /proc, and those of the cgroup
/// v2 that `/proc/self/cgroup` names, under /sys/fs/cgroup.
async fn ProcessFiles::of_self() -> ProcessFiles {
  {
    stat: "/proc/self/stat",
    status: "/proc/self/status",
    cgroup_dir: read_text(proc_self_cgroup).bind(@usage.cgroup_dir),
  }
}

///|
/// The process and cgroup metrics of one process. A metric whose file
/// smock cannot read, or does not understand, when it starts is not
/// registered, and so not in /metrics: all of them without /proc; those of
/// the cgroup outside a cgroup v2; the CFS counts without the cgroup's cpu
/// controller, which a CPU limit enables; and the memory peak without
/// `memory.peak` (Linux before 5.19, or no memory controller). A file that
/// cannot be read or understood at a scrape leaves its metrics as they
/// were.
priv struct ProcessMetrics {
  /// Where the metrics are read from.
  files : ProcessFiles
  /// `process_cpu_seconds_total`.
  cpu : @metrics.CounterSeries?
  /// `process_resident_memory_bytes`.
  resident : @metrics.GaugeSeries?
  /// The metrics of smock's cgroup.
  cgroup : CgroupMetrics?
}

///|
/// The metrics of the cgroup v2 that smock runs in.
priv struct CgroupMetrics {
  /// The cgroup's directory, under /sys/fs/cgroup.
  dir : String
  /// `smock_cgroup_cpu_usage_seconds_total`.
  usage : @metrics.CounterSeries?
  /// `smock_cgroup_cpu_periods_total`.
  periods : @metrics.CounterSeries?
  /// `smock_cgroup_cpu_throttled_periods_total`.
  throttled_periods : @metrics.CounterSeries?
  /// `smock_cgroup_cpu_throttled_seconds_total`.
  throttled : @metrics.CounterSeries?
  /// `smock_cgroup_memory_peak_bytes`.
  memory_peak : @metrics.GaugeSeries?
}

///|
/// Registers the process and cgroup metrics in `metrics`, those whose
/// `files` smock can read now, and reads them. `started_at` is when the
/// process started, in milliseconds since the Unix epoch.
async fn ProcessMetrics::register(
  metrics : @metrics.Registry,
  started_at~ : Int64,
  files~ : ProcessFiles,
) -> ProcessMetrics {
  metrics
  .gauge(
    "process_start_time_seconds",
    help="When the smock process started, in seconds since the Unix epoch. It changes when the process restarts.",
  )
  .labels([])
  .set(started_at.to_double() / 1000.0)
  let cpu = if read_text(files.stat).bind(@usage.cpu_seconds) is Some(_) {
    Some(
      metrics
      .counter(
        "process_cpu_seconds_total",
        help="CPU time the smock process has used, user and system, in seconds, to the hundredth of a second (utime and stime of /proc/self/stat).",
      )
      .labels([]),
    )
  } else {
    None
  }
  let resident = if read_text(files.status).bind(@usage.resident_bytes)
    is Some(_) {
    Some(
      metrics
      .gauge(
        "process_resident_memory_bytes",
        help="The smock process's resident set size, in bytes (VmRSS of /proc/self/status).",
      )
      .labels([]),
    )
  } else {
    None
  }
  let cgroup = match files.cgroup_dir {
    Some(dir) => Some(register_cgroup(metrics, dir))
    None => None
  }
  let process = { files, cpu, resident, cgroup, }
  process.update()
  process
}

///|
/// Registers the metrics of smock's cgroup, whose directory is `dir`, that
/// smock can read now.
async fn register_cgroup(
  metrics : @metrics.Registry,
  dir : String,
) -> CgroupMetrics {
  let stat = read_text("\{dir}/cpu.stat").map(@usage.CpuStat::parse)
  let usage = if stat is Some({ usage_usec: Some(_), .. }) {
    Some(
      metrics
      .counter(
        "smock_cgroup_cpu_usage_seconds_total",
        help="CPU time smock's cgroup has used, in seconds, to the microsecond (usage_usec of its cpu.stat): smock's, and that of any other process in the cgroup.",
      )
      .labels([]),
    )
  } else {
    None
  }
  let cfs = stat
    is Some(
      {
        nr_periods: Some(_),
        nr_throttled: Some(_),
        throttled_usec: Some(_),
        ..
      }
    )
  let periods = if cfs {
    Some(
      metrics
      .counter(
        "smock_cgroup_cpu_periods_total",
        help="CFS periods that have elapsed while smock's cgroup had something to run, under its CPU quota (nr_periods of its cpu.stat). A CPU limit in Kubernetes has periods of 100 ms.",
      )
      .labels([]),
    )
  } else {
    None
  }
  let throttled_periods = if cfs {
    Some(
      metrics
      .counter(
        "smock_cgroup_cpu_throttled_periods_total",
        help="CFS periods in which smock's cgroup used up its CPU quota and was held back until the next one (nr_throttled of its cpu.stat).",
      )
      .labels([]),
    )
  } else {
    None
  }
  let throttled = if cfs {
    Some(
      metrics
      .counter(
        "smock_cgroup_cpu_throttled_seconds_total",
        help="How long the CPU quota held smock's cgroup back, in seconds (throttled_usec of its cpu.stat).",
      )
      .labels([]),
    )
  } else {
    None
  }
  let memory_peak = if read_text("\{dir}/memory.peak").bind(@usage.memory_peak)
    is Some(_) {
    Some(
      metrics
      .gauge(
        "smock_cgroup_memory_peak_bytes",
        help="The most memory smock's cgroup has used since it was made, in bytes (its memory.peak): all that its memory.max limits, socket buffers and page cache included.",
      )
      .labels([]),
    )
  } else {
    None
  }
  { dir, usage, periods, throttled_periods, throttled, memory_peak, }
}

///|
/// Brings the metrics up to date from their files. A file that cannot be
/// read or understood now leaves its metrics as they were.
async fn ProcessMetrics::update(self : ProcessMetrics) -> Unit {
  if self.cpu is Some(cpu) &&
    read_text(self.files.stat).bind(@usage.cpu_seconds) is Some(seconds) {
    cpu.advance_to(seconds)
  }
  if self.resident is Some(resident) &&
    read_text(self.files.status).bind(@usage.resident_bytes) is Some(bytes) {
    resident.set(bytes.to_double())
  }
  guard self.cgroup is Some(cgroup) else { return }
  if cgroup.usage is Some(_) || cgroup.periods is Some(_) {
    if read_text("\{cgroup.dir}/cpu.stat") is Some(text) {
      let stat = @usage.CpuStat::parse(text)
      advance(cgroup.usage, stat.usage_usec, per_second=1.0e6)
      advance(cgroup.periods, stat.nr_periods)
      advance(cgroup.throttled_periods, stat.nr_throttled)
      advance(cgroup.throttled, stat.throttled_usec, per_second=1.0e6)
    }
  }
  if cgroup.memory_peak is Some(peak) &&
    read_text("\{cgroup.dir}/memory.peak").bind(@usage.memory_peak)
    is Some(bytes) {
    peak.set(bytes.to_double())
  }
}

///|
/// Advances `counter`, when it is registered, to `count`, when the file had
/// it, in units of which there are `per_second` in a second for a time.
fn advance(
  counter : @metrics.CounterSeries?,
  count : Int64?,
  per_second? : Double = 1.0,
) -> Unit {
  if counter is Some(counter) && count is Some(count) {
    counter.advance_to(count.to_double() / per_second)
  }
}

///|
/// The text of the file at `path`, or `None` when it cannot be read.
async fn read_text(path : String) -> String? {
  try @fs.read_file(path).text() catch {
    _ => None
  } noraise {
    text => Some(text)
  }
}
