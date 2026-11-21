// The ranges of smock serve's numeric settings, at each end: the value at
// each end is accepted, and the value just past it is refused with the
// message a user sees, as is a value that is not a decimal integer. Each is
// given by the flag and, apart, by its variable, which the Settings table
// pairs with it (#320). The e2e settings test refuses some of these values
// through the binary; these run in-process. The message names the flag and
// its variable, as docs/running.md's Settings table pairs them, in the form
// `InvalidSetting::message` documents, and the range in the words `must be
// an integer from <min> to <max>`. No document gives those words: they are
// the code's, which the maintainer confirmed on 2026-11-17 (#275), and the
// e2e settings test pins them too.

///|
/// What `smock serve <argv>` makes of its settings: `show` of the settings
/// when they are valid, or the message a user sees when they are not.
fn serve_with(
  argv : Array[String],
  show : (@settings.ServeSettings) -> Int32,
) -> String {
  let matches = @settings.serve_command().parse(argv~, env={}) catch {
    err => return "parse: \{err}"
  }
  try @settings.ServeSettings::from_matches(matches) catch {
    err => err.message()
  } noraise {
    settings => show(settings).to_string()
  }
}

///|
/// What `smock serve` makes of `value`, given by the flag `flag` and, apart,
/// by its variable `variable`: `show` of the settings when they are valid,
/// or the message a user sees when they are not, after the value and a
/// colon. One result when the flag and the variable give the same, as the
/// Settings table pairs them, and both when they do not.
fn by_flag_and_variable(
  flag : String,
  variable : String,
  value : String,
  show : (@settings.ServeSettings) -> String,
) -> String {
  let read = (argv : Array[String], env : Map[String, String]) => {
    let matches = @settings.serve_command().parse(argv~, env~) catch {
      err => return "parse: \{err}"
    }
    try @settings.ServeSettings::from_matches(matches) catch {
      err => err.message()
    } noraise {
      settings => show(settings)
    }
  }
  // `--port=-1`, as a user gives a value that starts with `-`.
  let by_flag = read(["\{flag}=\{value}"], {})
  let by_variable = read([], Map([(variable, value)]))
  if by_flag == by_variable {
    "\{value}: \{by_flag}"
  } else {
    "\{value}: \{by_flag}; by \{variable}: \{by_variable}"
  }
}

///|
/// `by_flag_and_variable` for each of `values`, one line each.
fn each_by_flag_and_variable(
  flag : String,
  variable : String,
  values : Array[String],
  show : (@settings.ServeSettings) -> String,
) -> String {
  values
  .map(value => by_flag_and_variable(flag, variable, value, show))
  .join("\n")
}

///|
test "ranges: each port, by its flag or its variable, takes 0 and 65535, and refuses -1, 65536 and a value that is not a decimal integer" {
  // docs/running.md, Settings: each port's flag and variable, and "0 picks
  // a free port". RFC 9293, section 3.1: a TCP header's Source Port and
  // Destination Port are 16 bits each, so a port is a number from 0 to
  // 65535. A value with leading zeros is the integer it writes, however
  // many zeros it has (#426): 00000008080, eleven characters, and 8080
  // after twenty zeros are 8080.
  inspect(
    [
      each_by_flag_and_variable(
        "--port",
        "SMOCK_PORT",
        [
          "0", "65535", "-1", "65536", "eighty", "00000008080", "000000000000000000008080",
        ],
        settings => settings.port.to_string(),
      ),
      each_by_flag_and_variable(
        "--tls-port",
        "SMOCK_TLS_PORT",
        ["0", "65535", "-1", "65536", "https"],
        settings => settings.tls_port.to_string(),
      ),
      each_by_flag_and_variable(
        "--admin-port",
        "SMOCK_ADMIN_PORT",
        ["0", "65535", "-1", "65536", "0x50"],
        settings => settings.admin_port.to_string(),
      ),
    ].join("\n"),
    content=(
      #|0: 0
      #|65535: 65535
      #|-1: invalid value "-1" for --port (SMOCK_PORT): must be an integer from 0 to 65535
      #|65536: invalid value "65536" for --port (SMOCK_PORT): must be an integer from 0 to 65535
      #|eighty: invalid value "eighty" for --port (SMOCK_PORT): must be an integer from 0 to 65535
      #|00000008080: 8080
      #|000000000000000000008080: 8080
      #|0: 0
      #|65535: 65535
      #|-1: invalid value "-1" for --tls-port (SMOCK_TLS_PORT): must be an integer from 0 to 65535
      #|65536: invalid value "65536" for --tls-port (SMOCK_TLS_PORT): must be an integer from 0 to 65535
      #|https: invalid value "https" for --tls-port (SMOCK_TLS_PORT): must be an integer from 0 to 65535
      #|0: 0
      #|65535: 65535
      #|-1: invalid value "-1" for --admin-port (SMOCK_ADMIN_PORT): must be an integer from 0 to 65535
      #|65536: invalid value "65536" for --admin-port (SMOCK_ADMIN_PORT): must be an integer from 0 to 65535
      #|0x50: invalid value "0x50" for --admin-port (SMOCK_ADMIN_PORT): must be an integer from 0 to 65535
    ),
  )
}

///|
test "ranges: each port flag takes 65535, the largest port TCP's 16-bit fields hold, and refuses 65536" {
  // RFC 9293, section 3.1: a TCP header's Source Port and Destination Port
  // are 16 bits each, so 65535 is the largest port.
  let port = (settings : @settings.ServeSettings) => settings.port
  let tls_port = (settings : @settings.ServeSettings) => settings.tls_port
  let admin_port = (settings : @settings.ServeSettings) => settings.admin_port
  inspect(
    [
      serve_with(["--port", "65535"], port),
      serve_with(["--tls-port", "65535"], tls_port),
      serve_with(["--admin-port", "65535"], admin_port),
      serve_with(["--port", "65536"], port),
      serve_with(["--tls-port", "65536"], tls_port),
      serve_with(["--admin-port", "65536"], admin_port),
    ].join("\n"),
    content=(
      #|65535
      #|65535
      #|65535
      #|invalid value "65536" for --port (SMOCK_PORT): must be an integer from 0 to 65535
      #|invalid value "65536" for --tls-port (SMOCK_TLS_PORT): must be an integer from 0 to 65535
      #|invalid value "65536" for --admin-port (SMOCK_ADMIN_PORT): must be an integer from 0 to 65535
    ),
  )
}

///|
test "ranges: --replicas takes 10000 and refuses 10001" {
  // docs/running.md, Settings: --replicas takes 1 to 10000.
  let replicas = (settings : @settings.ServeSettings) => settings.replicas
  inspect(
    [
      serve_with(["--replicas", "10000"], replicas),
      serve_with(["--replicas", "10001"], replicas),
    ].join("\n"),
    content=(
      #|10000
      #|invalid value "10001" for --replicas (SMOCK_REPLICAS): must be an integer from 1 to 10000
    ),
  )
}

///|
test "ranges: --header-count-limit takes 1073741824 and refuses 1073741825" {
  // docs/running.md, Settings: --header-count-limit takes 1 to 1073741824
  // (2^30).
  let header_count_limit = (settings : @settings.ServeSettings) => {
    settings.header_count_limit
  }
  inspect(
    [
      serve_with(["--header-count-limit", "1073741824"], header_count_limit),
      serve_with(["--header-count-limit", "1073741825"], header_count_limit),
    ].join("\n"),
    content=(
      #|1073741824
      #|invalid value "1073741825" for --header-count-limit (SMOCK_HEADER_COUNT_LIMIT): must be an integer from 1 to 1073741824
    ),
  )
}

///|
test "ranges: --journal-max-entries takes 1073741824 and refuses 1073741825" {
  // docs/running.md, Settings: --journal-max-entries takes 1 to 1073741824
  // (2^30).
  let journal_max_entries = (settings : @settings.ServeSettings) => {
    settings.journal_max_entries
  }
  inspect(
    [
      serve_with(["--journal-max-entries", "1073741824"], journal_max_entries),
      serve_with(["--journal-max-entries", "1073741825"], journal_max_entries),
    ].join("\n"),
    content=(
      #|1073741824
      #|invalid value "1073741825" for --journal-max-entries (SMOCK_JOURNAL_MAX_ENTRIES): must be an integer from 1 to 1073741824
    ),
  )
}

///|
test "ranges: --replicas, by its flag or SMOCK_REPLICAS, takes 1 and 10000, and refuses 0, 10001 and a value that is not a decimal integer" {
  // docs/running.md, Settings: --replicas takes 1 to 10000. A larger value
  // is refused however large it is (#426): 18446744073709551617, 2^64 + 1,
  // is not 1, which it would be in a 64-bit integer that wraps.
  inspect(
    each_by_flag_and_variable(
      "--replicas",
      "SMOCK_REPLICAS",
      ["1", "10000", "0", "10001", "two", "18446744073709551617"],
      settings => settings.replicas.to_string(),
    ),
    content=(
      #|1: 1
      #|10000: 10000
      #|0: invalid value "0" for --replicas (SMOCK_REPLICAS): must be an integer from 1 to 10000
      #|10001: invalid value "10001" for --replicas (SMOCK_REPLICAS): must be an integer from 1 to 10000
      #|two: invalid value "two" for --replicas (SMOCK_REPLICAS): must be an integer from 1 to 10000
      #|18446744073709551617: invalid value "18446744073709551617" for --replicas (SMOCK_REPLICAS): must be an integer from 1 to 10000
    ),
  )
}

///|
test "ranges: --header-count-limit, by its flag or SMOCK_HEADER_COUNT_LIMIT, takes 1 and 1073741824, and refuses 0, 1073741825 and a value that is not a decimal integer" {
  // docs/running.md, Settings: --header-count-limit takes 1 to 1073741824
  // (2^30).
  inspect(
    each_by_flag_and_variable(
      "--header-count-limit",
      "SMOCK_HEADER_COUNT_LIMIT",
      ["1", "1073741824", "0", "1073741825", "100.0"],
      settings => settings.header_count_limit.to_string(),
    ),
    content=(
      #|1: 1
      #|1073741824: 1073741824
      #|0: invalid value "0" for --header-count-limit (SMOCK_HEADER_COUNT_LIMIT): must be an integer from 1 to 1073741824
      #|1073741825: invalid value "1073741825" for --header-count-limit (SMOCK_HEADER_COUNT_LIMIT): must be an integer from 1 to 1073741824
      #|100.0: invalid value "100.0" for --header-count-limit (SMOCK_HEADER_COUNT_LIMIT): must be an integer from 1 to 1073741824
    ),
  )
}

///|
test "ranges: --journal-max-entries, by its flag or SMOCK_JOURNAL_MAX_ENTRIES, takes 1 and 1073741824, and refuses 0, 1073741825 and a value that is not a decimal integer" {
  // docs/running.md, Settings: --journal-max-entries takes 1 to 1073741824
  // (2^30).
  inspect(
    each_by_flag_and_variable(
      "--journal-max-entries",
      "SMOCK_JOURNAL_MAX_ENTRIES",
      ["1", "1073741824", "0", "1073741825", "10k"],
      settings => settings.journal_max_entries.to_string(),
    ),
    content=(
      #|1: 1
      #|1073741824: 1073741824
      #|0: invalid value "0" for --journal-max-entries (SMOCK_JOURNAL_MAX_ENTRIES): must be an integer from 1 to 1073741824
      #|1073741825: invalid value "1073741825" for --journal-max-entries (SMOCK_JOURNAL_MAX_ENTRIES): must be an integer from 1 to 1073741824
      #|10k: invalid value "10k" for --journal-max-entries (SMOCK_JOURNAL_MAX_ENTRIES): must be an integer from 1 to 1073741824
    ),
  )
}

///|
test "ranges: --http2-max-concurrent-streams, by its flag or SMOCK_HTTP2_MAX_CONCURRENT_STREAMS, takes 1 and 1000, and refuses 0, 1001 and a value that is not a decimal integer" {
  // docs/running.md, Settings: --http2-max-concurrent-streams takes 1 to
  // 1000.
  inspect(
    each_by_flag_and_variable(
      "--http2-max-concurrent-streams",
      "SMOCK_HTTP2_MAX_CONCURRENT_STREAMS",
      ["1", "1000", "0", "1001", "ten"],
      settings => settings.http2_max_concurrent_streams.to_string(),
    ),
    content=(
      #|1: 1
      #|1000: 1000
      #|0: invalid value "0" for --http2-max-concurrent-streams (SMOCK_HTTP2_MAX_CONCURRENT_STREAMS): must be an integer from 1 to 1000
      #|1001: invalid value "1001" for --http2-max-concurrent-streams (SMOCK_HTTP2_MAX_CONCURRENT_STREAMS): must be an integer from 1 to 1000
      #|ten: invalid value "ten" for --http2-max-concurrent-streams (SMOCK_HTTP2_MAX_CONCURRENT_STREAMS): must be an integer from 1 to 1000
    ),
  )
}

///|
/// The seed of the process generator that settings hold, or `none`.
fn seed(settings : @settings.ServeSettings) -> String {
  match settings.seed {
    Some(seed) => seed.to_string()
    None => "none"
  }
}

///|
test "ranges: --seed, by its flag or SMOCK_SEED, takes 0 and 2^53 - 1, and refuses -1, 2^53 and a value that is not a decimal integer" {
  // docs/running.md, Settings: --seed and SMOCK_SEED set the seed of the
  // process generator, which smock otherwise picks "from 0 to
  // 9007199254740991" (2^53 - 1), as a Stub's seed takes
  // (docs/definition-files/faults.md, Seeds). A value with leading zeros is
  // the integer it writes (#426): 00000000000000007, seventeen characters,
  // is 7.
  inspect(
    each_by_flag_and_variable(
      "--seed",
      "SMOCK_SEED",
      [
        "0", "9007199254740991", "-1", "9007199254740992", "0x2a", "00000000000000007",
      ],
      seed,
    ),
    content=(
      #|0: 0
      #|9007199254740991: 9007199254740991
      #|-1: invalid value "-1" for --seed (SMOCK_SEED): must be an integer from 0 to 9007199254740991
      #|9007199254740992: invalid value "9007199254740992" for --seed (SMOCK_SEED): must be an integer from 0 to 9007199254740991
      #|0x2a: invalid value "0x2a" for --seed (SMOCK_SEED): must be an integer from 0 to 9007199254740991
      #|00000000000000007: 7
    ),
  )
}

///|
test "ranges: without --seed, smock picks a seed from 0 to 2^53 - 1, one that --seed takes" {
  // docs/running.md, Settings: without --seed, "smock picks the seed of its
  // random generator, from 0 to 9007199254740991".
  let picked = @settings.random_seed()
  inspect(
    [
      (picked <= 9007199254740991UL).to_string(),
      (@settings.parse_seed(picked.to_string()) == Some(picked)).to_string(),
    ].join(" "),
    content="true true",
  )
  // It is a fresh seed, picked at each start ("smock picks its seed at
  // startup and logs it. To replay a run, start smock with that seed",
  // docs/definition-files/faults.md, Seeds; "a fresh seed",
  // docs/definition-files/templates.md, Rendering a template): one pick
  // from 2^53 values is 0 once in 2^53, so smock does not settle on 0.
  inspect(picked == 0, content="false")
}

///|
/// The byte bound that `bound` gives settings, in bytes, or `none` when
/// it leaves it to the memory limit.
fn max_bytes(bound : @settings.ByteBound?) -> String {
  match bound {
    Some(bound) => bound.max_bytes.to_string()
    None => "none"
  }
}

///|
test "ranges: --journal-max-bytes and --state-max-bytes, by their flags or variables, take 1 and 1073741824, and refuse 0, 1073741825 and a value that is not a decimal integer" {
  // docs/definition-files/variables.md, The state bound: --state-max-bytes
  // or SMOCK_STATE_MAX_BYTES "sets it, in bytes, from 1 to 1073741824 (1
  // GiB), as --journal-max-bytes takes".
  inspect(
    [
      each_by_flag_and_variable(
        "--journal-max-bytes",
        "SMOCK_JOURNAL_MAX_BYTES",
        ["1", "1073741824", "0", "1073741825", "64MiB"],
        settings => max_bytes(settings.journal_max_bytes),
      ),
      each_by_flag_and_variable(
        "--state-max-bytes",
        "SMOCK_STATE_MAX_BYTES",
        ["1", "1073741824", "0", "1073741825", "1e6"],
        settings => max_bytes(settings.state_max_bytes),
      ),
    ].join("\n"),
    content=(
      #|1: 1
      #|1073741824: 1073741824
      #|0: invalid value "0" for --journal-max-bytes (SMOCK_JOURNAL_MAX_BYTES): must be an integer from 1 to 1073741824
      #|1073741825: invalid value "1073741825" for --journal-max-bytes (SMOCK_JOURNAL_MAX_BYTES): must be an integer from 1 to 1073741824
      #|64MiB: invalid value "64MiB" for --journal-max-bytes (SMOCK_JOURNAL_MAX_BYTES): must be an integer from 1 to 1073741824
      #|1: 1
      #|1073741824: 1073741824
      #|0: invalid value "0" for --state-max-bytes (SMOCK_STATE_MAX_BYTES): must be an integer from 1 to 1073741824
      #|1073741825: invalid value "1073741825" for --state-max-bytes (SMOCK_STATE_MAX_BYTES): must be an integer from 1 to 1073741824
      #|1e6: invalid value "1e6" for --state-max-bytes (SMOCK_STATE_MAX_BYTES): must be an integer from 1 to 1073741824
    ),
  )
}

///|
test "ranges: --header-size-limit, by its flag or SMOCK_HEADER_SIZE_LIMIT, takes 1 and 1073741824, and refuses 0, 1073741825 and a value that is not a decimal integer" {
  // docs/running.md, Settings: --header-size-limit takes 1 to 1073741824
  // (2^30), as the maintainer confirmed on 2026-11-18 (#320).
  inspect(
    each_by_flag_and_variable(
      "--header-size-limit",
      "SMOCK_HEADER_SIZE_LIMIT",
      ["1", "1073741824", "0", "1073741825", "16KiB"],
      settings => settings.header_size_limit.to_string(),
    ),
    content=(
      #|1: 1
      #|1073741824: 1073741824
      #|0: invalid value "0" for --header-size-limit (SMOCK_HEADER_SIZE_LIMIT): must be an integer from 1 to 1073741824
      #|1073741825: invalid value "1073741825" for --header-size-limit (SMOCK_HEADER_SIZE_LIMIT): must be an integer from 1 to 1073741824
      #|16KiB: invalid value "16KiB" for --header-size-limit (SMOCK_HEADER_SIZE_LIMIT): must be an integer from 1 to 1073741824
    ),
  )
}

///|
test "ranges: --body-limit, by its flag or SMOCK_BODY_LIMIT, takes 0 and 1073741824, and refuses -1, 1073741825 and a value that is not a decimal integer" {
  // docs/running.md, Settings: --body-limit takes 0 to 1073741824 (2^30),
  // as the maintainer confirmed on 2026-11-18 (#320).
  inspect(
    each_by_flag_and_variable(
      "--body-limit",
      "SMOCK_BODY_LIMIT",
      ["0", "1073741824", "-1", "1073741825", "10MiB"],
      settings => settings.body_limit.to_string(),
    ),
    content=(
      #|0: 0
      #|1073741824: 1073741824
      #|-1: invalid value "-1" for --body-limit (SMOCK_BODY_LIMIT): must be an integer from 0 to 1073741824
      #|1073741825: invalid value "1073741825" for --body-limit (SMOCK_BODY_LIMIT): must be an integer from 0 to 1073741824
      #|10MiB: invalid value "10MiB" for --body-limit (SMOCK_BODY_LIMIT): must be an integer from 0 to 1073741824
    ),
  )
}

///|
test "ranges: the read, idle and write timeouts, by their flags or variables, take 1 and 2147483647, the drain timeout 0 and 2147483647, and each refuses the value past each end and a value that is not a decimal integer" {
  // docs/running.md, Settings: --read-timeout-ms, --idle-timeout-ms and
  // --write-timeout-ms take 1 to 2147483647 (2^31 - 1), and
  // --drain-timeout-ms 0 to 2147483647, as the maintainer confirmed on
  // 2026-11-18 (#320).
  inspect(
    [
      each_by_flag_and_variable(
        "--read-timeout-ms",
        "SMOCK_READ_TIMEOUT_MS",
        ["1", "2147483647", "0", "2147483648", "30s"],
        settings => settings.read_timeout_ms.to_string(),
      ),
      each_by_flag_and_variable(
        "--idle-timeout-ms",
        "SMOCK_IDLE_TIMEOUT_MS",
        ["1", "2147483647", "0", "2147483648", "1m"],
        settings => settings.idle_timeout_ms.to_string(),
      ),
      each_by_flag_and_variable(
        "--write-timeout-ms",
        "SMOCK_WRITE_TIMEOUT_MS",
        ["1", "2147483647", "0", "2147483648", "30000ms"],
        settings => settings.write_timeout_ms.to_string(),
      ),
      each_by_flag_and_variable(
        "--drain-timeout-ms",
        "SMOCK_DRAIN_TIMEOUT_MS",
        ["0", "2147483647", "-1", "2147483648", "20s"],
        settings => settings.drain_timeout_ms.to_string(),
      ),
    ].join("\n"),
    content=(
      #|1: 1
      #|2147483647: 2147483647
      #|0: invalid value "0" for --read-timeout-ms (SMOCK_READ_TIMEOUT_MS): must be an integer from 1 to 2147483647
      #|2147483648: invalid value "2147483648" for --read-timeout-ms (SMOCK_READ_TIMEOUT_MS): must be an integer from 1 to 2147483647
      #|30s: invalid value "30s" for --read-timeout-ms (SMOCK_READ_TIMEOUT_MS): must be an integer from 1 to 2147483647
      #|1: 1
      #|2147483647: 2147483647
      #|0: invalid value "0" for --idle-timeout-ms (SMOCK_IDLE_TIMEOUT_MS): must be an integer from 1 to 2147483647
      #|2147483648: invalid value "2147483648" for --idle-timeout-ms (SMOCK_IDLE_TIMEOUT_MS): must be an integer from 1 to 2147483647
      #|1m: invalid value "1m" for --idle-timeout-ms (SMOCK_IDLE_TIMEOUT_MS): must be an integer from 1 to 2147483647
      #|1: 1
      #|2147483647: 2147483647
      #|0: invalid value "0" for --write-timeout-ms (SMOCK_WRITE_TIMEOUT_MS): must be an integer from 1 to 2147483647
      #|2147483648: invalid value "2147483648" for --write-timeout-ms (SMOCK_WRITE_TIMEOUT_MS): must be an integer from 1 to 2147483647
      #|30000ms: invalid value "30000ms" for --write-timeout-ms (SMOCK_WRITE_TIMEOUT_MS): must be an integer from 1 to 2147483647
      #|0: 0
      #|2147483647: 2147483647
      #|-1: invalid value "-1" for --drain-timeout-ms (SMOCK_DRAIN_TIMEOUT_MS): must be an integer from 0 to 2147483647
      #|2147483648: invalid value "2147483648" for --drain-timeout-ms (SMOCK_DRAIN_TIMEOUT_MS): must be an integer from 0 to 2147483647
      #|20s: invalid value "20s" for --drain-timeout-ms (SMOCK_DRAIN_TIMEOUT_MS): must be an integer from 0 to 2147483647
    ),
  )
}

///|
test "ranges: --journal-body-limit, by its flag or SMOCK_JOURNAL_BODY_LIMIT, takes 0 and 1073741824, and refuses -1, 1073741825 and a value that is not a decimal integer" {
  // docs/running.md, Settings: --journal-body-limit takes 0 to 1073741824
  // (2^30), as the maintainer confirmed on 2026-11-18 (#320).
  inspect(
    each_by_flag_and_variable(
      "--journal-body-limit",
      "SMOCK_JOURNAL_BODY_LIMIT",
      ["0", "1073741824", "-1", "1073741825", "4KiB"],
      settings => settings.journal_body_limit.to_string(),
    ),
    content=(
      #|0: 0
      #|1073741824: 1073741824
      #|-1: invalid value "-1" for --journal-body-limit (SMOCK_JOURNAL_BODY_LIMIT): must be an integer from 0 to 1073741824
      #|1073741825: invalid value "1073741825" for --journal-body-limit (SMOCK_JOURNAL_BODY_LIMIT): must be an integer from 0 to 1073741824
      #|4KiB: invalid value "4KiB" for --journal-body-limit (SMOCK_JOURNAL_BODY_LIMIT): must be an integer from 0 to 1073741824
    ),
  )
}
