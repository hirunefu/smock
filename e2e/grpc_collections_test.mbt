// Seam 2 tests of request messages with repeated fields, maps and oneofs
// over h2c, decoded into smock's decoded form, which the Journal records
// and conditions match. The set is
// fixtures/protobuf/collections/collections.proto, and the messages are
// what protoc encodes from the .txtpb files beside it
// (scripts/gen-protobuf-fixtures.sh), so the codec is never checked
// against itself. A call may send several of them joined: protobuf's
// parsers read joined messages as one message, merged, and so the tests
// send records in orders protoc never writes.

///|
/// The directory of the collections fixtures.
let collections_dir : String = "fixtures/protobuf/collections"

///|
/// The framed message that the messages protoc encoded from each
/// `<name>.txtpb` of `names` in the collections fixtures make, joined in
/// order.
async fn collections_message(names : Array[String]) -> Bytes {
  let out = @buffer.Buffer()
  for name in names {
    out.write_bytes(@fs.read_file("\{collections_dir}/\{name}.binpb").binary())
  }
  framed(out.to_bytes())
}

///|
/// Runs `f` with a definitions directory holding `shelf.yaml`, whose text
/// is `yaml`, and the set of collections.proto at
/// `files/collections.binpb`.
async fn with_collections_set(
  yaml : String,
  f : async (String) -> Unit,
) -> Unit {
  with_definitions([("shelf.yaml", yaml)], dir => {
    @fs.mkdir("\{dir}/files")
    write_bytes(
      dir,
      "files/collections.binpb",
      @fs.read_file("\{collections_dir}/collections.binpb").binary(),
    )
    f(dir)
  })
}

///|
/// Calls `path` once with each message of `calls`, each the names of the
/// collections messages to join, and fails unless each gets
/// `grpc-status` `status`.
async fn H2Client::call_each(
  self : H2Client,
  path : String,
  calls : Array[Array[String]],
  status~ : String = "0",
) -> Unit {
  for names in calls {
    let body = if names.is_empty() {
      framed(b"")
    } else {
      collections_message(names)
    }
    let reply = self.call(path, body~)
    let fields = match reply.trailers {
      Some(trailers) => trailers
      None => reply.head
    }
    guard fields.contains(("grpc-status", status)) else {
      fail("\{names.join("+")}: \{reply.render()}")
    }
  }
}

///|
async test "the ticket's example: two encodings of one message, one with its fields in reverse order and its map entries shuffled, are journaled with one text and meet one Stub, and an unmatched call's Near miss shows the same form" {
  let yaml =
    #|mocks:
    #|  - name: shelf
    #|    grpc: { descriptorSet: collections.binpb }
    #|stubs:
    #|  - id: tagged
    #|    mock: shelf
    #|    request: { path: /collections.Shelf/Tag, body: { json: { tags: [a, b], counts: { "10": 1 } } } }
    #|    response: { json: {} }
  with_collections_set(yaml, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      // protoc's encoding; the map entries shuffled, then the tags.
      client.call_each("/collections.Shelf/Tag", [
        ["tagged"],
        ["tagged-counts", "tagged-tags"],
      ])
      // The tags alone meet no Stub.
      client.call_each("/collections.Shelf/Tag", [["tagged-tags"]], status="12")
      inspect(
        smock.bodies(),
        content=(
          #|"tagged": {"tags":["a","b"],"counts":{"1":3,"2":5,"10":1}}
          #|"tagged": {"tags":["a","b"],"counts":{"1":3,"2":5,"10":1}}
          #|null: {"tags":["a","b"],"counts":{}}
        ),
      )
      let (_, journal) = smock.journal()
      guard journal
        is Object(
          { "entries": [_, _, Object({ "nearMiss": near_miss, .. })], .. }
        ) else {
        fail("not three entries: \{journal.stringify()}")
      }
      inspect(
        near_miss.stringify(),
        content=(
          #|{"stub":"tagged","stubSource":"file","failed":[{"condition":"body","expected":{"json":{"tags":["a","b"],"counts":{"10":1}}},"actual":["{\"tags\":[\"a\",\"b\"],\"counts\":{}}"]}]}
        ),
      )
    })
  })
}

///|
async test "repeated fields are journaled as arrays: packed and unpacked scalars alike, the records of a packed field joined, and [] for an empty one" {
  let yaml =
    #|mocks:
    #|  - name: shelf
    #|    grpc: { descriptorSet: collections.binpb }
    #|stubs:
    #|  - id: packed-or-not
    #|    mock: shelf
    #|    request: { path: /collections.Shelf/Fill, body: { json: { numbers: [1, -2, 300], weights: [0.1, 9.99] } } }
    #|    response: { json: {} }
    #|  - id: joined
    #|    mock: shelf
    #|    request: { path: /collections.Shelf/Fill, body: { json: { numbers: [1, -2, 300, 4, 5] } } }
    #|    response: { json: {} }
    #|  - id: empty
    #|    mock: shelf
    #|    request: { path: /collections.Shelf/Fill, body: { json: { numbers: [], items: [] } } }
    #|    response: { json: {} }
  with_collections_set(yaml, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      // Packed, unpacked, each followed by two more numbers packed in one
      // record, and an empty message.
      client.call_each("/collections.Shelf/Fill", [
        ["lists"],
        ["lists-on-the-wire"],
        ["lists", "lists-more"],
        ["lists-on-the-wire", "lists-more"],
        [],
      ])
      inspect(
        smock.bodies(),
        content=(
          #|"packed-or-not": {"numbers":[1,-2,300],"offsets":[-1,64],"codes":[7,4294967295],"ratios":[0.5,-1e+300],"weights":[0.1,9.99],"flags":[true,false,true],"kinds":["BOOK","DISC",9],"words":["x","Kyōto"],"blobs":["AP8="],"items":[{"name":"pen","sizes":[1,2],"stock":{"a":1}},{"name":"","sizes":[],"stock":{}}]}
          #|"packed-or-not": {"numbers":[1,-2,300],"offsets":[-1,64],"codes":[7,4294967295],"ratios":[0.5,-1e+300],"weights":[0.1,9.99],"flags":[true,false,true],"kinds":["BOOK","DISC",9],"words":["x","Kyōto"],"blobs":["AP8="],"items":[{"name":"pen","sizes":[1,2],"stock":{"a":1}},{"name":"","sizes":[],"stock":{}}]}
          #|"joined": {"numbers":[1,-2,300,4,5],"offsets":[-1,64],"codes":[7,4294967295],"ratios":[0.5,-1e+300],"weights":[0.1,9.99],"flags":[true,false,true],"kinds":["BOOK","DISC",9],"words":["x","Kyōto"],"blobs":["AP8="],"items":[{"name":"pen","sizes":[1,2],"stock":{"a":1}},{"name":"","sizes":[],"stock":{}}]}
          #|"joined": {"numbers":[1,-2,300,4,5],"offsets":[-1,64],"codes":[7,4294967295],"ratios":[0.5,-1e+300],"weights":[0.1,9.99],"flags":[true,false,true],"kinds":["BOOK","DISC",9],"words":["x","Kyōto"],"blobs":["AP8="],"items":[{"name":"pen","sizes":[1,2],"stock":{"a":1}},{"name":"","sizes":[],"stock":{}}]}
          #|"empty": {"numbers":[],"offsets":[],"codes":[],"ratios":[],"weights":[],"flags":[],"kinds":[],"words":[],"blobs":[],"items":[]}
        ),
      )
    })
  })
}

///|
async test "maps are journaled as objects in key order, integer keys by value, bool keys false then true and string keys by their text; an entry without a key or a value takes the default, the last entry of a repeated key wins, and an empty map is {}" {
  let yaml =
    #|mocks:
    #|  - name: shelf
    #|    grpc: { descriptorSet: collections.binpb }
    #|stubs:
    #|  - id: gaps
    #|    mock: shelf
    #|    request: { path: /collections.Shelf/Count, body: { json: { byId: { "0": no key, "5": "", "7": second } } } }
    #|    response: { json: {} }
    #|  - id: ordered
    #|    mock: shelf
    #|    request: { path: /collections.Shelf/Count, body: { json: { byFlag: { "false": 2, "true": 1 } } } }
    #|    response: { json: {} }
    #|  - id: any-maps
    #|    mock: shelf
    #|    request: { path: /collections.Shelf/Count }
    #|    response: { json: {} }
  with_collections_set(yaml, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      client.call_each("/collections.Shelf/Count", [["maps"], ["maps-gaps"], []])
      inspect(
        smock.bodies(),
        content=(
          #|"ordered": {"byId":{"-9223372036854775808":"smallest","-1":"minus one","2":"two","10":"ten","9223372036854775807":"largest"},"byCode":{"7":true,"10":true,"4294967295":true},"byOffset":{"-20":"DISC","-5":"BOOK","3":"BOOK"},"byFlag":{"false":2,"true":1},"byName":{"B":{"name":"big bee","sizes":[],"stock":{}},"a":{"name":"ay","sizes":[],"stock":{}},"b":{"name":"bee","sizes":[],"stock":{}},"é":{"name":"e acute","sizes":[],"stock":{}}}}
          #|"gaps": {"byId":{"0":"no key","5":"","7":"second"},"byCode":{},"byOffset":{"0":"KIND_UNSPECIFIED"},"byFlag":{"false":3},"byName":{"":{"name":"no key","sizes":[],"stock":{}},"pen":{"name":"","sizes":[],"stock":{}}}}
          #|"any-maps": {"byId":{},"byCode":{},"byOffset":{},"byFlag":{},"byName":{}}
        ),
      )
    })
  })
}

///|
async test "a oneof member is journaled only when set, a later member replacing an earlier one, and the values of a message field are merged" {
  let yaml =
    #|mocks:
    #|  - name: shelf
    #|    grpc: { descriptorSet: collections.binpb }
    #|stubs:
    #|  - id: word
    #|    mock: shelf
    #|    request: { path: /collections.Shelf/Choose, body: { json: { word: { $exists: true } } } }
    #|    response: { json: {} }
    #|  - id: number
    #|    mock: shelf
    #|    request: { path: /collections.Shelf/Choose, body: { json: { number: 0 } } }
    #|    response: { json: {} }
    #|  - id: item
    #|    mock: shelf
    #|    request: { path: /collections.Shelf/Choose, body: { json: { item: { $exists: true } } } }
    #|    response: { json: {} }
    #|  - id: no-member
    #|    mock: shelf
    #|    request:
    #|      path: /collections.Shelf/Choose
    #|      body: { json: { word: { $exists: false }, number: { $exists: false }, item: { $exists: false } } }
    #|    response: { json: {} }
  with_collections_set(yaml, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      client.call_each("/collections.Shelf/Choose", [
        // Each member, set to its default but for the message.
        ["choice-word"],
        ["choice-number"],
        ["choice-item"],
        // Every member, the message last; the message, then the string.
        ["choice-every"],
        ["choice-item", "choice-word"],
        // The message twice, merged, and with another member between,
        // not merged.
        ["choice-item", "choice-item"],
        ["choice-item", "choice-number", "choice-item"],
        // Two values of a message field outside the oneof, merged.
        ["box-first", "box-second"],
      ])
      inspect(
        smock.bodies(),
        content=(
          #|"word": {"label":"w","word":""}
          #|"number": {"label":"","number":0}
          #|"item": {"label":"","item":{"name":"pen","sizes":[1],"stock":{}}}
          #|"item": {"label":"every","item":{"name":"pen","sizes":[],"stock":{}}}
          #|"word": {"label":"w","word":""}
          #|"item": {"label":"","item":{"name":"pen","sizes":[1,1],"stock":{}}}
          #|"item": {"label":"","item":{"name":"pen","sizes":[1],"stock":{}}}
          #|"no-member": {"label":"","box":{"name":"pen","sizes":[1,2],"stock":{"a":2,"b":5,"c":3}}}
        ),
      )
    })
  })
}
