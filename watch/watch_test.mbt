// What a watch tells besides its checks. How its polls glance, stamp and
// check is for the white-box tests in watch_wbtest.mbt, which script the
// stamps and glances on a clock of their own, and when the stamps come is
// for the Schedule tests to check.

///|
async test "a file time ahead of the clock is told once, and again only after a stamp noted none" {
  let dir = @fs.tmpdir(prefix="smock-watch-")
  defer @fs.rmdir(dir, recursive=true)
  let path = "\{dir}/users.json"
  @fs.write_file(path, "{}")
  let set_ahead = async fn() {
    let ahead = @async.now() / 1000 + 86_400
    let status = @process.run("touch", ["-m", "-d", "@\{ahead}", path])
    guard status == 0 else { fail("touch exited with \{status}") }
  }
  set_ahead()
  let out = []
  let checks = Ref(0)
  @async.with_task_group(group => {
    let watch = @watch.Watch(stamp=stamp => stamp.note_file(path))
    group.spawn_bg(no_wait=true, () => {
      watch.run(
        check => {
          out.push(@debug.to_string(check))
          checks.val += 1
        },
        on_ahead=(file, _) => out.push("ahead: \{file == path}"),
      )
    })
    // The first poll checks with the same time ahead, since the stamp
    // taken at the start is too new to be trusted. Each step comes after
    // the check before it.
    let steps : Array[async () -> Unit] = [
      () => @fs.write_file(path, "{}"),
      () => set_ahead(),
      () => (),
    ]
    for i, step in steps {
      let checked = @async.with_timeout_opt(5000, () => {
        while checks.val <= i {
          @async.sleep(20)
        }
      })
      guard checked is Some(_) else {
        fail("too few checks in time: \{out.join(" ")}")
      }
      step()
    }
  })
  inspect(
    out.join("\n"),
    content=(
      #|ahead: true
      #|Unsure
      #|Changed
      #|ahead: true
      #|Changed
    ),
  )
}
