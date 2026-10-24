// Seam 2 tests of HTTP/2 on the plain port by prior knowledge (h2c): the
// preface check, the mapping of a stream onto the engine's request, the
// response written on the stream, and what stays HTTP/1.1.

///|
async test "h2c: a request is answered by the Stub of the Mock its :authority names, and is in the Journal as HTTP/2, with its target and Host and no pseudo-header fields, once the response is read" {
  with_definitions(two_mocks(default=false), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let out = []
      for host in ["orders.example.com", "users.example.com"] {
        let response = client.request("GET", "/x?a=1", authority=host, headers=[
          ("accept", "text/plain"),
        ])
        out.push(response.render())
        let (status, journal) = smock.journal()
        out.push("journal: \{status}")
        guard journal is Object({ "entries": Array(entries), .. }) else {
          fail("no entries: \{journal.stringify()}")
        }
        out.push(journal_shown(entries[entries.length() - 1]).stringify())
      }
      inspect(
        out.join("\n"),
        content=(
          #|200
          #|date: <now>
          #|content-length: 11
          #|
          #|from orders
          #|journal: 200
          #|{"seq":1,"receivedAt":"<time>","durationMs":"<ms>","session":null,"host":"orders.example.com","mock":"orders","viaDefault":false,"digest":"<digest>","request":{"method":"GET","target":"/x?a=1","version":"HTTP/2","headers":[{"name":"accept","value":"text/plain"}],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"orders-x","stubSource":"file","scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":200,"fault":null,"templateError":null}
          #|200
          #|date: <now>
          #|content-length: 10
          #|
          #|from users
          #|journal: 200
          #|{"seq":2,"receivedAt":"<time>","durationMs":"<ms>","session":null,"host":"users.example.com","mock":"users","viaDefault":false,"digest":"<digest>","request":{"method":"GET","target":"/x?a=1","version":"HTTP/2","headers":[{"name":"accept","value":"text/plain"}],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"users-x","stubSource":"file","scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":200,"fault":null,"templateError":null}
        ),
      )
    })
  })
}
