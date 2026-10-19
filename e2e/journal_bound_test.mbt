// The Journal's byte bound at startup: what --journal-max-bytes or
// SMOCK_JOURNAL_MAX_BYTES sets, or else a quarter of the memory limit of
// smock's cgroup. smock runs in a systemd user scope with MemoryMax, as
// bench/bench.py runs it, so that its cgroup has a known memory limit.

///|
/// The memory limit of the scopes smock runs in here: 52Mi, that of the
/// smallest GKE Autopilot Pod where Pods may burst, in whole pages of 4 KiB
/// and of 16 KiB.
let scope_memory_max : String = "54525952"

///|
/// The command that runs the command after it in a new systemd user scope
/// whose cgroup has the memory limit `scope_memory_max`. It becomes that
/// command by exec, so the command keeps its process ID.
let in_scope : Array[String] = [
  "systemd-run",
  "--user",
  "--scope",
  "--quiet",
  "--collect",
  "-p",
  "MemoryMax=\{scope_memory_max}",
  "--",
]

///|
/// What `systemd-run --user` needs from the environment to reach the
/// systemd user manager, since the harness gives smock no other variables.
fn user_manager_env(env : Map[String, String]) -> Map[String, String] {
  let out = Map::from_iter(env.iter())
  for name in ["XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"] {
    if @env.get_env_var(name) is Some(value) {
      out[name] = value
    }
  }
  out
}

///|
/// Why smock cannot run in a scope with a memory limit here, or `None` when
/// it can: a shell run as `in_scope` prints its own cgroup's memory.max,
/// which must be the scope's limit.
async fn scope_unavailable() -> String? {
  let script = "cat \"/sys/fs/cgroup$(sed -n 's/^0:://p' /proc/self/cgroup)/memory.max\""
  let command = [..in_scope, "sh", "-c", script]
  let (status, output) = collect_output_merged(
    command[0],
    command[1:].to_owned(),
  ) catch {
    err => return Some("systemd-run cannot be run: \{err}")
  }
  let text = output.text().trim(chars="\n").to_owned()
  if status != 0 {
    Some("systemd-run --user failed with exit status \{status}: \{text}")
  } else if text != scope_memory_max {
    Some(
      "a scope with MemoryMax=\{scope_memory_max} got memory.max \{text.escape()}: the systemd user manager needs the memory controller delegated to it (see bench/README.md)",
    )
  } else {
    None
  }
}

///|
/// The `journal byte bound` log entry, without its time.
fn journal_bound_entry(logs : Array[String]) -> String {
  for line in logs {
    let entry = @json.parse(line) catch { _ => continue }
    guard entry is Object(fields) &&
      fields.get("msg") is Some(String("journal byte bound")) else {
      continue
    }
    fields.remove("time")
    return Json::object(fields).stringify()
  }
  "no journal byte bound entry in:\n\{logs.join("\n")}"
}

///|
async test "journal byte bound: a quarter of the memory limit of smock's cgroup, unless the flag or the variable sets it" {
  if scope_unavailable() is Some(reason) {
    println(
      "skipped \"journal byte bound\" (e2e/journal_bound_test.mbt): it runs smock in a systemd user scope with a memory limit, but \{reason}",
    )
    return
  }
  let cases : Array[(Array[String], Map[String, String])] = [
    ([], {}),
    (["--journal-max-bytes", "1000000"], {}),
    ([], { "SMOCK_JOURNAL_MAX_BYTES": "2000000" }),
  ]
  let out = []
  for case in cases {
    let (args, env) = case
    let stopped = with_smock(
      ["--port", "0", ..args],
      env=user_manager_env(env),
      under=in_scope,
      _ => (),
    )
    out.push(journal_bound_entry(stopped.logs))
  }
  inspect(
    out.join("\n"),
    content=(
      #|{"level":"info","msg":"journal byte bound","maxBytes":13631488,"source":"memoryLimit","memoryLimit":54525952}
      #|{"level":"info","msg":"journal byte bound","maxBytes":1000000,"source":"flag"}
      #|{"level":"info","msg":"journal byte bound","maxBytes":2000000,"source":"variable"}
    ),
  )
}

///|
/// The value of the sample `name` without labels in the Prometheus `text`.
fn metric_value(text : String, name : String) -> Double raise {
  for line in metric_lines(text, name + " ") {
    return @string.parse_double(line[name.length() + 1:]) catch { _ => break }
  }
  fail("no sample \{name} in:\n\{text}")
}

///|
async test "journal byte bound: the Journal holds no more than the bound smock logs, and evicts beyond it" {
  with_definitions([("users.json", journal_defs)], dir => {
    let stopped = with_smock(
      ["--dir", dir, "--port", "0", "--journal-max-bytes", "1000"],
      smock => {
        // Each entry counts at least 256 bytes, so four overflow the bound.
        for i in 1..<=4 {
          let _ = smock.request("GET", "/users/\{i}", headers=[
            ("Host", "localhost"),
          ])
        }
        let text = smock.admin("GET", "/metrics").body
        let bytes = metric_value(text, "smock_journal_bytes")
        let evictions = metric_value(text, "smock_journal_evictions_total")
        inspect(
          "within the bound: \{bytes > 0.0 && bytes <= 1000.0}, evicted: \{evictions > 0.0}",
          content="within the bound: true, evicted: true",
        )
      },
    )
    inspect(
      journal_bound_entry(stopped.logs),
      content=(
        #|{"level":"info","msg":"journal byte bound","maxBytes":1000,"source":"flag"}
      ),
    )
  })
}
