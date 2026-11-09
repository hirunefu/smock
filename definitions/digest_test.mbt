// The definition set digest computed a step at a time, as a reload computes
// it so that requests are answered between steps. The expected values were
// computed outside smock, with Python's hashlib, over the framing
// docs/definition-files.md describes, and are those smock gave before the
// digest was computed in steps.

///|
/// A Definition file `users.json` with a body file `users/1.json`, a body
/// file of 1,000 bytes that spans several SHA-256 blocks, an empty one and
/// one whose name is not ASCII.
let digest_fixture : @definitions.DefinitionSet = {
  files: [
    (
      "users.json",
      @utf8.encode(
        (
          #|{ "mocks": [{ "name": "users", "hosts": ["users.example.com"] }],
          #|  "stubs": [{ "id": "get-user", "mock": "users",
          #|    "request": { "method": "GET", "path": "/users/1" },
          #|    "response": { "status": 200, "bodyFile": "users/1.json" } }] }
        ),
      ),
    ),
  ],
  body_files: [
    ("users/1.json", b"{\"id\":1,\"name\":\"Alice\"}"),
    ("big.bin", Bytes::makei(1000, i => (i % 251).to_byte())),
    ("empty.txt", b""),
    ("é.txt", b"x"),
  ],
}

///|
/// The digest of `set` computed with steps of `budget` bytes, and how many
/// steps it took.
fn digest_in_steps(
  set : @definitions.DefinitionSet,
  budget : Int32,
) -> (String, Int32) {
  let digester = set.digester()
  let mut steps = 1
  for ;; {
    if digester.step(budget~) is Some(digest) {
      return (digest, steps)
    }
    steps += 1
  }
}

///|
test "the digest is the same whether it is computed at once or in steps of any size" {
  // The framed set is 1,390 bytes long, so steps of 64 bytes take 22 steps.
  inspect(digest_fixture.digest(), content="ef54f5875c20")
  inspect(
    [1, 7, 55, 56, 63, 64, 65, 100, 1000, 1390, 1_000_000]
    .map(budget => {
      let (digest, steps) = digest_in_steps(digest_fixture, budget)
      "\{budget}: \{digest} in \{steps} steps"
    })
    .join("\n"),
    content=(
      #|1: ef54f5875c20 in 1390 steps
      #|7: ef54f5875c20 in 199 steps
      #|55: ef54f5875c20 in 26 steps
      #|56: ef54f5875c20 in 25 steps
      #|63: ef54f5875c20 in 23 steps
      #|64: ef54f5875c20 in 22 steps
      #|65: ef54f5875c20 in 22 steps
      #|100: ef54f5875c20 in 14 steps
      #|1000: ef54f5875c20 in 2 steps
      #|1390: ef54f5875c20 in 1 steps
      #|1000000: ef54f5875c20 in 1 steps
    ),
  )
}

///|
test "a digester gives its digest again once it is done, and an empty set has the digest of no bytes" {
  let digester = digest_fixture.digester()
  debug_inspect(digester.step(budget=1000), content="None")
  let first = digester.step(budget=1000)
  debug_inspect(first, content="Some(\"ef54f5875c20\")")
  inspect(digester.step(budget=1) == first, content="true")
  let empty : @definitions.DefinitionSet = { files: [], body_files: [], }
  debug_inspect(
    empty.digester().step(budget=1),
    content="Some(\"e3b0c44298fc\")",
  )
}
