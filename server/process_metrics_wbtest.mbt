///|
/// The samples `registry` renders, one a line, without the `# HELP` and
/// `# TYPE` lines.
fn samples(registry : @metrics.Registry) -> String {
  registry
  .render()
  .split("\n")
  .filter(line => line != "" && !line.has_prefix("#"))
  .map(line => line.to_owned())
  .collect()
  .join("\n")
}

///|
/// A line of /proc/<pid>/stat as Linux writes it, with `utime` and `stime`
/// clock ticks of CPU time.
fn proc_stat(utime : Int, stime : Int) -> String {
  "4242 (smock) S 1 4242 4242 0 -1 4194304 92 0 0 0 \{utime} \{stime} 0 0 20 0 1 0 37096714 6946816 99 18446744073709551615\n"
}

///|
async test "process metrics: read at each scrape; a file missing at startup leaves its metrics out, and one that cannot be read or understood at a scrape leaves them as they were" {
  let dir = @fs.tmpdir(prefix="smock-process-metrics-")
  defer @fs.rmdir(dir, recursive=true)
  let cgroup = "\{dir}/cgroup"
  @fs.mkdir(cgroup)
  @fs.write_file("\{dir}/stat", proc_stat(150, 25))
  @fs.write_file("\{dir}/status", "Name:\tsmock\nVmRSS:\t    6896 kB\n")
  // A cgroup without the cpu controller, so no CFS counts, and without
  // memory.peak, as on Linux before 5.19.
  @fs.write_file(
    "\{cgroup}/cpu.stat",
    "usage_usec 2034567\nuser_usec 1534567\nsystem_usec 500000\n",
  )
  let registry = @metrics.Registry()
  let process = ProcessMetrics::register(registry, started_at=1791993354147L, files={
    stat: "\{dir}/stat",
    status: "\{dir}/status",
    cgroup_dir: Some(cgroup),
  })
  let out = ["At startup:", samples(registry)]
  // Every file says more, and the counts and the file that were not there
  // at startup appear: their metrics stay out.
  @fs.write_file("\{dir}/stat", proc_stat(310, 40))
  @fs.write_file("\{dir}/status", "Name:\tsmock\nVmRSS:\t    7168 kB\n")
  @fs.write_file(
    "\{cgroup}/cpu.stat",
    "usage_usec 3500000\nnr_periods 7\nnr_throttled 1\nthrottled_usec 2000\n",
  )
  @fs.write_file("\{cgroup}/memory.peak", "44040192\n")
  process.update()
  out.push("A scrape later:")
  out.push(samples(registry))
  // Files that say nothing it understands, then no files at all.
  @fs.write_file("\{dir}/stat", "4242 (smock) S\n")
  @fs.write_file("\{dir}/status", "Name:\tsmock\n")
  @fs.write_file("\{cgroup}/cpu.stat", "")
  process.update()
  out.push("Files it does not understand:")
  out.push(samples(registry))
  for file in ["stat", "status", "cgroup/cpu.stat", "cgroup/memory.peak"] {
    @fs.remove("\{dir}/\{file}")
  }
  process.update()
  out.push("No files:")
  out.push(samples(registry))
  inspect(
    out.join("\n"),
    content=(
      #|At startup:
      #|process_start_time_seconds 1791993354.147
      #|process_cpu_seconds_total 1.75
      #|process_resident_memory_bytes 7061504
      #|smock_cgroup_cpu_usage_seconds_total 2.034567
      #|A scrape later:
      #|process_start_time_seconds 1791993354.147
      #|process_cpu_seconds_total 3.5
      #|process_resident_memory_bytes 7340032
      #|smock_cgroup_cpu_usage_seconds_total 3.5
      #|Files it does not understand:
      #|process_start_time_seconds 1791993354.147
      #|process_cpu_seconds_total 3.5
      #|process_resident_memory_bytes 7340032
      #|smock_cgroup_cpu_usage_seconds_total 3.5
      #|No files:
      #|process_start_time_seconds 1791993354.147
      #|process_cpu_seconds_total 3.5
      #|process_resident_memory_bytes 7340032
      #|smock_cgroup_cpu_usage_seconds_total 3.5
    ),
  )
}

///|
async test "cgroup metrics: with the cpu controller and memory.peak at startup, each count of cpu.stat and the memory peak, read at each scrape" {
  let dir = @fs.tmpdir(prefix="smock-process-metrics-")
  defer @fs.rmdir(dir, recursive=true)
  @fs.write_file("\{dir}/stat", proc_stat(150, 25))
  @fs.write_file("\{dir}/status", "VmRSS:\t    6896 kB\n")
  // A container with a CPU limit, as cpu.stat has it on Linux 6.
  @fs.write_file(
    "\{dir}/cpu.stat",
    (
      #|usage_usec 2034567
      #|user_usec 1534567
      #|system_usec 500000
      #|nr_periods 420
      #|nr_throttled 17
      #|throttled_usec 912345
      #|nr_bursts 0
      #|burst_usec 0
      #|
    ),
  )
  @fs.write_file("\{dir}/memory.peak", "44040192\n")
  let registry = @metrics.Registry()
  let process = ProcessMetrics::register(registry, started_at=1791993354147L, files={
    stat: "\{dir}/stat",
    status: "\{dir}/status",
    cgroup_dir: Some(dir),
  })
  let out = [samples(registry)]
  @fs.write_file(
    "\{dir}/cpu.stat",
    "usage_usec 2534567\nnr_periods 425\nnr_throttled 19\nthrottled_usec 1012345\n",
  )
  @fs.write_file("\{dir}/memory.peak", "46137344\n")
  process.update()
  out.push(samples(registry))
  inspect(
    out.join("\n\n"),
    content=(
      #|process_start_time_seconds 1791993354.147
      #|process_cpu_seconds_total 1.75
      #|process_resident_memory_bytes 7061504
      #|smock_cgroup_cpu_usage_seconds_total 2.034567
      #|smock_cgroup_cpu_periods_total 420
      #|smock_cgroup_cpu_throttled_periods_total 17
      #|smock_cgroup_cpu_throttled_seconds_total 0.912345
      #|smock_cgroup_memory_peak_bytes 44040192
      #|
      #|process_start_time_seconds 1791993354.147
      #|process_cpu_seconds_total 1.75
      #|process_resident_memory_bytes 7061504
      #|smock_cgroup_cpu_usage_seconds_total 2.534567
      #|smock_cgroup_cpu_periods_total 425
      #|smock_cgroup_cpu_throttled_periods_total 19
      #|smock_cgroup_cpu_throttled_seconds_total 1.012345
      #|smock_cgroup_memory_peak_bytes 46137344
    ),
  )
}
