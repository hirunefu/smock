///|
/// The resident memory of this process, in KiB, as /proc gives it.
async fn resident_kib() -> Int32 {
  let status = @fs.read_file("/proc/self/status").text()
  for line in status.split("\n") {
    if line.has_prefix("VmRSS:") {
      return @string.parse_int(line[6:].trim(chars=" \tkB")) catch {
        _ => fail("VmRSS unreadable: \{line}")
      }
    }
  }
  fail("no VmRSS in /proc/self/status")
}

///|
async test "a stopwatch holds no memory once it is dropped: starting a million keeps the process's memory flat" {
  let before = resident_kib()
  let mut total = 0.0
  for i in 0..<1_000_000 {
    let stopwatch = Stopwatch::start()
    if i % 1000 == 0 {
      total += stopwatch.seconds()
    }
  }
  let grown = resident_kib() - before
  // A timestamp that leaked would take about 32 bytes each: 31 MiB.
  inspect(
    "grew by less than 4 MiB: \{grown < 4096}, times read: \{total >= 0.0}",
    content="grew by less than 4 MiB: true, times read: true",
  )
}
