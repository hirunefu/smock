///|
/// The name of this replica: the host name the kernel gives it, which in
/// Kubernetes is the Pod's hostname. It comes from
/// `/proc/sys/kernel/hostname` on Linux and from `uname -n` elsewhere, so
/// no C is needed (ADR 0001). `unknown` when neither gives one.
async fn replica_name() -> String {
  let from_proc = @fs.read_file("/proc/sys/kernel/hostname").text() catch {
    _ => ""
  }
  match from_proc.trim() {
    "" => ()
    name => return name.to_owned()
  }
  let from_uname = @process.collect_stdout("uname", ["-n"]) catch {
    _ => (1, "")
  }
  match from_uname {
    (0, out) =>
      match out.text().trim() {
        "" => "unknown"
        name => name.to_owned()
      }
    _ => "unknown"
  }
}
