// Seam 2 tests of a Mock's Descriptor set: the set its grpc.descriptorSet
// names in the body-file subdirectory, read and checked with the
// Definition files by smock check, at startup and on reload. The sets are
// those scripts/gen-protobuf-fixtures.sh builds with protoc.

///|
/// The set protoc builds from gRPC's helloworld.proto.
let greeter_set_path : String = "fixtures/protobuf/helloworld/greeter.binpb"

///|
/// The same set, rebuilt with one more field in HelloReply.
let greeter_v2_set_path : String = "fixtures/protobuf/helloworld-v2/greeter.binpb"

///|
/// 32 random octets, which do not decode as a FileDescriptorSet.
let random_octets : Bytes = b"\xcb\x2b\x6b\x43\xd2\xf6\xaa\x36\x50\xa7\xd3\x25\xe0\x22\xeb\xb7\x4d\x65\x74\x96\x79\x68\x57\x9b\xe6\xc1\x69\xa5\x89\x44\xcf\x11"

///|
/// The Mock `greeter`, whose set is `files/<path>`.
fn greeter_mock(path : String) -> String {
  "{ \"mocks\": [{ \"name\": \"greeter\", \"grpc\": { \"descriptorSet\": \{path.escape()} } }] }"
}

///|
/// Writes `bytes` to `dir/path`, replacing what is there.
async fn write_bytes(dir : String, path : String, bytes : Bytes) -> Unit {
  @fs.write_file("\{dir}/\{path}", bytes)
}

///|
async test "smock check passes a Mock whose descriptorSet names the set of gRPC's helloworld.proto" {
  with_definitions(
    [("greeter.json", greeter_mock("greeter.binpb")), ("files/README", "")],
    dir => {
      write_bytes(
        dir,
        "files/greeter.binpb",
        @fs.read_file(greeter_set_path).binary(),
      )
      inspect(check([dir]), content="status 0\n")
    },
  )
}

///|
async test "a descriptorSet that names no file, leaves the body-file subdirectory, names a dot file or does not decode fails smock check with one problem at descriptorSet" {
  let cases = [
    ("missing.binpb", None),
    ("../greeter.binpb", None),
    (".greeter.binpb", Some(@fs.read_file(greeter_set_path).binary())),
    ("random.binpb", Some(random_octets)),
  ]
  let out = []
  for case in cases {
    let (path, bytes) = case
    with_definitions(
      [("greeter.json", greeter_mock(path)), ("files/README", "")],
      dir => {
        write_bytes(
          dir,
          "greeter.binpb",
          @fs.read_file(greeter_set_path).binary(),
        )
        if bytes is Some(bytes) {
          write_bytes(dir, "files/\{path}", bytes)
        }
        out.push(check([dir]))
      },
    )
  }
  inspect(
    out.join("---\n"),
    content=(
      #|status 1
      #|greeter.json: /mocks/0/grpc/descriptorSet: no body file "missing.binpb" in the body-file subdirectory
      #|---
      #|status 1
      #|greeter.json: /mocks/0/grpc/descriptorSet: must be a path inside the body-file subdirectory, such as users/1.json, with no name starting with .
      #|---
      #|status 1
      #|greeter.json: /mocks/0/grpc/descriptorSet: must be a path inside the body-file subdirectory, such as users/1.json, with no name starting with .
      #|---
      #|status 1
      #|greeter.json: /mocks/0/grpc/descriptorSet: "random.binpb": not a Descriptor set, a FileDescriptorSet in protobuf's binary encoding: octet 8: a length of 80 runs past the end of the input, which has 23 octets left
      #|
    ),
  )
}

///|
async test "a descriptorSet that a symlink leads outside the body-file subdirectory is a problem of the symlink, and none is read at descriptorSet" {
  with_definitions([("greeter.json", greeter_mock("greeter.binpb"))], dir => {
    write_bytes(dir, "greeter.binpb", @fs.read_file(greeter_set_path).binary())
    @fs.mkdir("\{dir}/files")
    @fs.symlink(target="../greeter.binpb", "\{dir}/files/greeter.binpb")
    inspect(
      check([dir]),
      content=(
        #|status 1
        #|files/greeter.binpb: leads outside the body-file subdirectory files, which body files must stay inside
        #|greeter.json: /mocks/0/grpc/descriptorSet: no body file "greeter.binpb" in the body-file subdirectory
        #|
      ),
    )
  })
}

///|
async test "smock serve does not start with a set that does not decode, and logs the problem at descriptorSet" {
  with_definitions([("greeter.json", greeter_mock("greeter.binpb"))], dir => {
    @fs.mkdir("\{dir}/files")
    write_bytes(dir, "files/greeter.binpb", random_octets)
    let stopped = run_smock(["serve", "--dir", dir, "--port", "0"])
    let invalid = stopped.logs.filter(line => {
      line.contains("invalid definitions")
    })
    inspect(
      "status \{stopped.status}\n" + log_entries(invalid),
      content=(
        #|status 1
        #|{"level":"error","msg":"invalid definitions","file":"greeter.json","pointer":"/mocks/0/grpc/descriptorSet","error":"\"greeter.binpb\": not a Descriptor set, a FileDescriptorSet in protobuf's binary encoding: octet 8: a length of 80 runs past the end of the input, which has 23 octets left"}
      ),
    )
  })
}

///|
async test "a reload swaps a set rebuilt with one more field and changes the digest, and keeps the digest it serves when the set does not decode" {
  with_definitions([("greeter.json", greeter_mock("greeter.binpb"))], dir => {
    @fs.mkdir("\{dir}/files")
    write_bytes(
      dir,
      "files/greeter.binpb",
      @fs.read_file(greeter_set_path).binary(),
    )
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let before = smock.status()
      write_bytes(
        dir,
        "files/greeter.binpb",
        @fs.read_file(greeter_v2_set_path).binary(),
      )
      let rebuilt = smock.reloaded(before)
      let changed = rebuilt.get("digest") != before.get("digest")
      write_bytes(dir, "files/greeter.binpb", random_octets)
      let broken = smock.reloaded(rebuilt)
      let kept = broken.get("digest") == rebuilt.get("digest")
      inspect(
        (
          $|rebuilt: \{last_reload(rebuilt)}, digest changed: \{changed}
          $|broken: \{last_reload(broken)}, digest kept: \{kept}
        ),
        content=(
          #|rebuilt: "swapped", digest changed: true
          #|broken: "failed"
          #|  {"file":"greeter.json","pointer":"/mocks/0/grpc/descriptorSet","message":"\"greeter.binpb\": not a Descriptor set, a FileDescriptorSet in protobuf's binary encoding: octet 8: a length of 80 runs past the end of the input, which has 23 octets left"}, digest kept: true
        ),
      )
    })
  })
}
