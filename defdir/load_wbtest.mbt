// What loading a definition set costs while smock serves: only a valid set is
// hashed, a step at a time, so `smock check` and a failed startup report an
// invalid set's problems without hashing its body files first.

///|
/// Whether another task ran while `work` did, which it can only at a pause,
/// and what `work` gave.
async fn[T] beside_another_task(work : async () -> T) -> (T, Bool) {
  let mut ran = 0
  let mut done = false
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      while !done {
        ran += 1
        @async.pause()
      }
    })
    let before = ran
    let result = work()
    done = true
    (result, ran > before)
  })
}

///|
async test "load_set hashes a valid set a step at a time, and an invalid one not at all" {
  // 1 MiB of body file: 17 steps of hashing, with a pause after each of the
  // first 16.
  let large = ("large.bin", Bytes::make(1024 * 1024, b'x'))
  let valid : @definitions.DefinitionSet = { files: [], body_files: [large], }
  let malformed : @definitions.DefinitionSet = {
    files: [("mocks.json", b"{")],
    body_files: [large],
  }
  let unreadable : @definitions.Diagnostic = {
    file: "users.json",
    pointer: "",
    message: "cannot be read",
  }
  let out = []
  let (loaded, paused) = beside_another_task(() => {
    load_set(valid, read_problems=[], env=@template.no_env)
  })
  out.push(
    "valid: digest \{loaded.map(snapshot => snapshot.digest) == Ok(valid.digest())}, other tasks ran: \{paused}",
  )
  let (loaded, paused) = beside_another_task(() => {
    load_set(malformed, read_problems=[], env=@template.no_env)
  })
  out.push(
    "a malformed Definition file: invalid \{loaded is Err(_)}, other tasks ran: \{paused}",
  )
  let (loaded, paused) = beside_another_task(() => {
    load_set(valid, read_problems=[unreadable], env=@template.no_env)
  })
  out.push(
    "a file that cannot be read: invalid \{loaded is Err(_)}, other tasks ran: \{paused}",
  )
  inspect(
    out.join("\n"),
    content=(
      #|valid: digest true, other tasks ran: true
      #|a malformed Definition file: invalid true, other tasks ran: false
      #|a file that cannot be read: invalid true, other tasks ran: false
    ),
  )
}
