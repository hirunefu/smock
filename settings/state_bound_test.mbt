// The byte bound on per-Session state: set explicitly, or derived from the
// memory limit of smock's cgroup by ADR 0004's rule with an eighth. The
// native server reads the limit once at startup, for this bound and the
// Journal's.

///|
/// The state bound the rule gives for `limit`, and what chose it, as
/// `<max bytes> <source>`.
fn state_derived(limit : @settings.MemoryLimit) -> String {
  let bound = @settings.ByteBound::state(limit)
  "\{bound.max_bytes} \{bound.source.name()}"
}

///|
test "state byte bound: an eighth of the memory limit when that is below 64 MiB" {
  inspect(
    [
      // The smallest GKE Autopilot Pod where Pods may burst: 52Mi.
      state_derived(Limited(54_525_952L)),
      // 256Mi.
      state_derived(Limited(268_435_456L)),
      // One 16 KiB page below 512Mi.
      state_derived(Limited(536_854_528L)),
      // An eighth rounds down: 52Mi and 7 bytes.
      state_derived(Limited(54_525_959L)),
    ].join("\n"),
    content=(
      #|6815744 memoryLimit
      #|33554432 memoryLimit
      #|67106816 memoryLimit
      #|6815744 memoryLimit
    ),
  )
}

///|
test "state byte bound: 64 MiB when an eighth of the memory limit is 64 MiB or more" {
  inspect(
    [
      // 512Mi: an eighth is exactly 64 MiB.
      state_derived(Limited(536_870_912L)),
      // 4Gi.
      state_derived(Limited(4_294_967_296L)),
      // The largest limit memory.max shows as a number on a 4 KiB-page
      // kernel.
      state_derived(Limited(9_223_372_036_854_771_712L)),
    ].join("\n"),
    content=(
      #|67108864 default
      #|67108864 default
      #|67108864 default
    ),
  )
}

///|
test "state byte bound: at least 1 MiB, however small the memory limit" {
  inspect(
    [
      // 8Mi: an eighth is exactly 1 MiB.
      state_derived(Limited(8_388_608L)),
      // One 4 KiB page below 8Mi.
      state_derived(Limited(8_384_512L)),
      // 4Mi, where the Journal's bound is exactly 1 MiB.
      state_derived(Limited(4_194_304L)),
      state_derived(Limited(0L)),
    ].join("\n"),
    content=(
      #|1048576 memoryLimit
      #|1048576 minimum
      #|1048576 minimum
      #|1048576 minimum
    ),
  )
}

///|
test "state byte bound: 64 MiB without a memory limit, or when it cannot be read" {
  inspect(
    [
      state_derived(Unlimited),
      state_derived(Unknown("/proc/self/cgroup names no cgroup v2")),
    ].join("\n"),
    content=(
      #|67108864 default
      #|67108864 default
    ),
  )
}

///|
/// The state bound that `smock serve <argv>` with the variables `env` sets
/// explicitly, or `None` when it leaves it to the memory limit.
fn explicit_state_bound(
  argv : Array[String],
  env : Map[String, String],
) -> @settings.ByteBound? raise {
  let matches = @settings.serve_command().parse(argv~, env~)
  @settings.ServeSettings::from_matches(matches).state_max_bytes
}

///|
test "state byte bound: an explicit flag or variable wins, the flag over the variable" {
  debug_inspect(
    [
      explicit_state_bound([], {}),
      explicit_state_bound(["--state-max-bytes", "1048576"], {}),
      explicit_state_bound([], { "SMOCK_STATE_MAX_BYTES": "2000" }),
      explicit_state_bound(["--state-max-bytes", "1048576"], {
        "SMOCK_STATE_MAX_BYTES": "2000",
      }),
    ],
    content=(
      #|[
      #|  None,
      #|  Some({ max_bytes: 1048576, source: Flag }),
      #|  Some({ max_bytes: 2000, source: Variable }),
      #|  Some({ max_bytes: 1048576, source: Flag }),
      #|]
    ),
  )
}

///|
test "state byte bound: it takes the values --journal-max-bytes takes, from 1 byte to 1 GiB" {
  let read = (value : String) => {
    let matches = @settings.serve_command().parse(
      argv=["--state-max-bytes", value],
      env={},
    ) catch {
      err => return "parse: \{err}"
    }
    try @settings.ServeSettings::from_matches(matches) catch {
      err => err.message()
    } noraise {
      settings => @debug.to_string(settings.state_max_bytes)
    }
  }
  inspect(
    ["1", "1073741824", "0", "1073741825", "1MiB", ""].map(read).join("\n"),
    content=(
      #|Some({ max_bytes: 1, source: Flag })
      #|Some({ max_bytes: 1073741824, source: Flag })
      #|invalid value "0" for --state-max-bytes (SMOCK_STATE_MAX_BYTES): must be an integer from 1 to 1073741824
      #|invalid value "1073741825" for --state-max-bytes (SMOCK_STATE_MAX_BYTES): must be an integer from 1 to 1073741824
      #|invalid value "1MiB" for --state-max-bytes (SMOCK_STATE_MAX_BYTES): must be an integer from 1 to 1073741824
      #|invalid value "" for --state-max-bytes (SMOCK_STATE_MAX_BYTES): must be an integer from 1 to 1073741824
    ),
  )
}

///|
test "state byte bound: the startup log names the bound, its source and the memory limit it came from" {
  let bounds : Array[@settings.ByteBound] = [
    { max_bytes: 1000, source: Flag, },
    { max_bytes: 2000, source: Variable, },
    @settings.ByteBound::state(Limited(54_525_952L)),
    @settings.ByteBound::state(Limited(4_194_304L)),
    @settings.ByteBound::state(Limited(4_294_967_296L)),
    @settings.ByteBound::state(Unlimited),
    @settings.ByteBound::state(Unknown("/proc/self/cgroup names no cgroup v2")),
  ]
  inspect(
    bounds.map(bound => Json::object(bound.log_fields()).stringify()).join("\n"),
    content=(
      #|{"maxBytes":1000,"source":"flag"}
      #|{"maxBytes":2000,"source":"variable"}
      #|{"maxBytes":6815744,"source":"memoryLimit","memoryLimit":54525952}
      #|{"maxBytes":1048576,"source":"minimum","memoryLimit":4194304}
      #|{"maxBytes":67108864,"source":"default","memoryLimit":4294967296}
      #|{"maxBytes":67108864,"source":"default","memoryLimit":"max"}
      #|{"maxBytes":67108864,"source":"default","memoryLimitError":"/proc/self/cgroup names no cgroup v2"}
    ),
  )
}
