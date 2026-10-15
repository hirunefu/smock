///|
test "process CPU: utime and stime of /proc/<pid>/stat, in seconds, after a command name with spaces and parentheses" {
  debug_inspect(
    [
      // A line as Linux 7.1 writes it: utime 1234 and stime 56 ticks.
      @usage.cpu_seconds(
        "3738363 (smock) S 3738362 3738363 3738362 0 -1 4194304 92 0 0 0 1234 56 0 0 20 0 1 0 37096714 6946816 99 18446744073709551615 187650144600064 187650144644700 281474850888432 0 0 0 0 0 0 0 0 0 17 3 0 0 0 0 0 187650144729232 187650144731428 187650434285568 281474850905386 281474850905406 281474850905406 281474850914283 0\n",
      ),
      // The command name is what the process chose, up to 15 bytes.
      @usage.cpu_seconds(
        "42 (a b) c)) R 1 42 42 0 -1 0 0 0 0 0 7 3 0 0 20 0 1 0 100 0 0 0\n",
      ),
      // A process that has not run a whole tick yet.
      @usage.cpu_seconds(
        "1 (smock) R 0 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 5 0 0 0\n",
      ),
      // Too few fields, a field that is not a number, and no line.
      @usage.cpu_seconds("1 (smock) R 0 1 1 0 -1 0 0 0 0 0 7\n"),
      @usage.cpu_seconds(
        "1 (smock) R 0 1 1 0 -1 0 0 0 0 0 -7 3 0 0 20 0 1 0 5 0 0 0\n",
      ),
      @usage.cpu_seconds(""),
    ],
    content=(
      #|[Some(12.9), Some(0.1), Some(0), None, None, None]
    ),
  )
}

///|
test "process RSS: the VmRSS line of /proc/<pid>/status, from KiB to bytes" {
  debug_inspect(
    [
      @usage.resident_bytes(
        "Name:\tsmock\nVmPeak:\t   61440 kB\nVmHWM:\t    6896 kB\nVmRSS:\t    6896 kB\nRssAnon:\t    1024 kB\n",
      ),
      // A kernel thread has no VmRSS.
      @usage.resident_bytes("Name:\tkthreadd\nState:\tS (sleeping)\n"),
      @usage.resident_bytes("VmRSS:\t    6896 MB\n"),
      @usage.resident_bytes("VmRSS:\t\n"),
      @usage.resident_bytes(""),
    ],
    content=(
      #|[Some(7061504), None, None, None, None]
    ),
  )
}

///|
test "cgroup: the directory of the cgroup v2 that /proc/self/cgroup names" {
  debug_inspect(
    [
      // A systemd scope on a cgroup v2 host.
      @usage.cgroup_dir(
        "0::/user.slice/user-1000.slice/user@1000.service/app.slice/run-r1.scope\n",
      ),
      // A container in its own cgroup namespace, as in Kubernetes: its
      // cgroup is the root of what it sees.
      @usage.cgroup_dir("0::/\n"),
      // A hybrid host: cgroup v1 hierarchies and the v2 one.
      @usage.cgroup_dir(
        "12:memory:/system.slice/a.service\n1:name=systemd:/system.slice/a.service\n0::/system.slice/a.service\n",
      ),
      // A cgroup v1 host.
      @usage.cgroup_dir("12:memory:/docker/0123\n1:cpu,cpuacct:/docker/0123\n"),
      @usage.cgroup_dir(""),
    ],
    content=(
      #|[
      #|  Some("/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice/run-r1.scope"),
      #|  Some("/sys/fs/cgroup"),
      #|  Some("/sys/fs/cgroup/system.slice/a.service"),
      #|  None,
      #|  None,
      #|]
    ),
  )
}

///|
test "cgroup CPU: cpu.stat has the usage always, and the CFS counts only with the cpu controller" {
  debug_inspect(
    [
      // A container with a CPU limit: the cpu controller is enabled.
      @usage.CpuStat::parse(
        (
          #|usage_usec 2034567
          #|user_usec 1534567
          #|system_usec 500000
          #|core_sched.force_idle_usec 0
          #|nr_periods 420
          #|nr_throttled 17
          #|throttled_usec 912345
          #|nr_bursts 0
          #|burst_usec 0
          #|
        ),
      ),
      // A cgroup without the cpu controller, such as a systemd scope that
      // has no CPUQuota.
      @usage.CpuStat::parse(
        (
          #|usage_usec 60736353202
          #|user_usec 53589353866
          #|system_usec 7146999335
          #|nice_usec 82200416
          #|
        ),
      ),
      @usage.CpuStat::parse("usage_usec -1\nnr_periods x\nnr_throttled\n"),
      @usage.CpuStat::parse(""),
    ],
    content=(
      #|[
      #|  {
      #|    usage_usec: Some(2034567),
      #|    nr_periods: Some(420),
      #|    nr_throttled: Some(17),
      #|    throttled_usec: Some(912345),
      #|  },
      #|  {
      #|    usage_usec: Some(60736353202),
      #|    nr_periods: None,
      #|    nr_throttled: None,
      #|    throttled_usec: None,
      #|  },
      #|  {
      #|    usage_usec: None,
      #|    nr_periods: None,
      #|    nr_throttled: None,
      #|    throttled_usec: None,
      #|  },
      #|  {
      #|    usage_usec: None,
      #|    nr_periods: None,
      #|    nr_throttled: None,
      #|    throttled_usec: None,
      #|  },
      #|]
    ),
  )
}

///|
test "cgroup memory: memory.peak holds a number of bytes" {
  debug_inspect(
    [
      @usage.memory_peak("44040192\n"),
      @usage.memory_peak("0\n"),
      @usage.memory_peak("9223372036854775807\n"),
      @usage.memory_peak("9223372036854775808\n"),
      @usage.memory_peak("max\n"),
      @usage.memory_peak(""),
    ],
    content=(
      #|[Some(44040192), Some(0), Some(9223372036854775807), None, None, None]
    ),
  )
}
