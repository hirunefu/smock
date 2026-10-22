// The Journal's byte bound: set explicitly, or derived from the memory limit
// of smock's cgroup, which the native server reads at startup and hands to
// the rule here.

///|
/// The bound the rule gives for `limit`, and what chose it, as
/// `<max bytes> <source>`.
fn derived(limit : @settings.MemoryLimit) -> String {
  let bound = @settings.ByteBound::journal(limit)
  "\{bound.max_bytes} \{bound.source.name()}"
}

///|
test "journal byte bound: a quarter of the memory limit when that is below 64 MiB" {
  inspect(
    [
      // The smallest GKE Autopilot Pod where Pods may burst: 52Mi.
      derived(Limited(54_525_952L)),
      // 128Mi.
      derived(Limited(134_217_728L)),
      // One 16 KiB page below 256Mi.
      derived(Limited(268_419_072L)),
      // A quarter rounds down: 52Mi and 3 bytes.
      derived(Limited(54_525_955L)),
    ].join("\n"),
    content=(
      #|13631488 memoryLimit
      #|33554432 memoryLimit
      #|67104768 memoryLimit
      #|13631488 memoryLimit
    ),
  )
}

///|
test "journal byte bound: 64 MiB when a quarter of the memory limit is 64 MiB or more" {
  inspect(
    [
      // 256Mi: a quarter is exactly 64 MiB.
      derived(Limited(268_435_456L)),
      // The smallest GKE Autopilot Pod where Pods may not burst: 512Mi.
      derived(Limited(536_870_912L)),
      // 4Gi.
      derived(Limited(4_294_967_296L)),
      // The largest limit memory.max shows as a number on a 4 KiB-page
      // kernel.
      derived(Limited(9_223_372_036_854_771_712L)),
    ].join("\n"),
    content=(
      #|67108864 default
      #|67108864 default
      #|67108864 default
      #|67108864 default
    ),
  )
}

///|
test "journal byte bound: at least 1 MiB, however small the memory limit" {
  inspect(
    [
      // 4Mi: a quarter is exactly 1 MiB.
      derived(Limited(4_194_304L)),
      // One 4 KiB page below 4Mi.
      derived(Limited(4_190_208L)),
      derived(Limited(0L)),
    ].join("\n"),
    content=(
      #|1048576 memoryLimit
      #|1048576 minimum
      #|1048576 minimum
    ),
  )
}

///|
test "journal byte bound: 64 MiB without a memory limit, or when it cannot be read" {
  inspect(
    [
      derived(Unlimited),
      derived(Unknown("/proc/self/cgroup names no cgroup v2")),
    ].join("\n"),
    content=(
      #|67108864 default
      #|67108864 default
    ),
  )
}

///|
/// The Journal's byte bound that `smock serve <argv>` with the variables
/// `env` sets explicitly, or `None` when it leaves it to the memory limit.
fn explicit_bound(
  argv : Array[String],
  env : Map[String, String],
) -> @settings.ByteBound? raise {
  let matches = @settings.serve_command().parse(argv~, env~)
  @settings.ServeSettings::from_matches(matches).journal_max_bytes
}

///|
test "journal byte bound: an explicit flag or variable wins, the flag over the variable" {
  debug_inspect(
    [
      explicit_bound([], {}),
      explicit_bound(["--journal-max-bytes", "1000"], {}),
      explicit_bound([], { "SMOCK_JOURNAL_MAX_BYTES": "2000" }),
      explicit_bound(["--journal-max-bytes", "1000"], {
        "SMOCK_JOURNAL_MAX_BYTES": "2000",
      }),
    ],
    content=(
      #|[
      #|  None,
      #|  Some({ max_bytes: 1000, source: Flag }),
      #|  Some({ max_bytes: 2000, source: Variable }),
      #|  Some({ max_bytes: 1000, source: Flag }),
      #|]
    ),
  )
}

///|
test "memory limit: the memory.max file of the cgroup v2 that /proc/self/cgroup names" {
  debug_inspect(
    [
      // A systemd scope on a cgroup v2 host.
      @settings.memory_max_file(
        "0::/user.slice/user-1000.slice/user@1000.service/app.slice/run-r1.scope\n",
      ),
      // A container in its own cgroup namespace, as in Kubernetes: its
      // cgroup is the root of what it sees.
      @settings.memory_max_file("0::/\n"),
      // A hybrid host: cgroup v1 hierarchies and the v2 one.
      @settings.memory_max_file(
        "12:memory:/system.slice/a.service\n1:name=systemd:/system.slice/a.service\n0::/system.slice/a.service\n",
      ),
      // A cgroup v1 host.
      @settings.memory_max_file(
        "12:memory:/docker/0123\n1:cpu,cpuacct:/docker/0123\n",
      ),
      @settings.memory_max_file(""),
    ],
    content=(
      #|[
      #|  Some("/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice/run-r1.scope/memory.max"),
      #|  Some("/sys/fs/cgroup/memory.max"),
      #|  Some("/sys/fs/cgroup/system.slice/a.service/memory.max"),
      #|  None,
      #|  None,
      #|]
    ),
  )
}

///|
test "memory limit: memory.max holds a number of bytes or max" {
  debug_inspect(
    [
      @settings.MemoryLimit::parse("54525952\n"),
      @settings.MemoryLimit::parse("max\n"),
      @settings.MemoryLimit::parse("0\n"),
      @settings.MemoryLimit::parse("9223372036854771712\n"),
      @settings.MemoryLimit::parse(""),
      @settings.MemoryLimit::parse("-1\n"),
      @settings.MemoryLimit::parse("52Mi\n"),
      @settings.MemoryLimit::parse("99999999999999999999\n"),
    ],
    content=(
      #|[
      #|  Some(Limited(54525952)),
      #|  Some(Unlimited),
      #|  Some(Limited(0)),
      #|  Some(Limited(9223372036854771712)),
      #|  None,
      #|  None,
      #|  None,
      #|  None,
      #|]
    ),
  )
}

///|
test "journal byte bound: the startup log names the bound, its source and the memory limit it came from" {
  let bounds : Array[@settings.ByteBound] = [
    { max_bytes: 1000, source: Flag, },
    { max_bytes: 2000, source: Variable, },
    @settings.ByteBound::journal(Limited(54_525_952L)),
    @settings.ByteBound::journal(Limited(2_097_152L)),
    @settings.ByteBound::journal(Limited(4_294_967_296L)),
    @settings.ByteBound::journal(Unlimited),
    @settings.ByteBound::journal(
      Unknown("/proc/self/cgroup names no cgroup v2"),
    ),
  ]
  inspect(
    bounds.map(bound => Json::object(bound.log_fields()).stringify()).join("\n"),
    content=(
      #|{"maxBytes":1000,"source":"flag"}
      #|{"maxBytes":2000,"source":"variable"}
      #|{"maxBytes":13631488,"source":"memoryLimit","memoryLimit":54525952}
      #|{"maxBytes":1048576,"source":"minimum","memoryLimit":2097152}
      #|{"maxBytes":67108864,"source":"default","memoryLimit":4294967296}
      #|{"maxBytes":67108864,"source":"default","memoryLimit":"max"}
      #|{"maxBytes":67108864,"source":"default","memoryLimitError":"/proc/self/cgroup names no cgroup v2"}
    ),
  )
}
