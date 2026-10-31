///|
/// 2026-10-31T09:00:01.250Z, the time of the spec's first example line.
let example_time : Int64 = 1_793_437_201_250L

///|
test "a Transaction recorded line names the Mock, the method, the path without the query and the status" {
  let prefix = @log.mockoon_prefix(Some("users"))
  inspect(
    @log.transaction_line(
      prefix,
      meth="GET",
      target="/users/1?verbose=true",
      status=200,
      at=example_time,
    ),
    content=(
      #|{"app":"smock","environmentName":"users","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/users/1","requestProxied":false,"responseStatus":200,"timestamp":"2026-10-31T09:00:01.250Z"}
    ),
  )
}

///|
/// The path of each target, from the line built for it: an origin-form
/// target, with and without a query; an absolute-form one, cut to its path,
/// with and without a port, a query or a path; the asterisk-form of OPTIONS
/// and the authority-form of CONNECT, which have no path to cut to; and
/// percent-escapes, which stay as sent.
test "requestPath is the target up to the query, an absolute-form target cut to its path, and / when it has none" {
  let prefix = @log.mockoon_prefix(Some("users"))
  let targets = [
    "/users/1", "/users/1?verbose=true", "/users/a%20b?q=%2F", "http://users.example.com/users/1",
    "http://users.example.com:8080/users/1?verbose=true", "HTTPS://users.example.com",
    "http://users.example.com?verbose=true", "*", "users.example.com:443", "/?",
    "/a?b?c",
  ]
  let out = []
  for target in targets {
    let line = @log.transaction_line(
      prefix,
      meth="GET",
      target~,
      status=200,
      at=example_time,
    )
    guard @json.parse(line) is Object(fields) &&
      fields.get("requestPath") is Some(String(path)) else {
      fail("no requestPath in \{line}")
    }
    out.push("\{target} => \{path}")
  }
  inspect(
    out.join("\n"),
    content=(
      #|/users/1 => /users/1
      #|/users/1?verbose=true => /users/1
      #|/users/a%20b?q=%2F => /users/a%20b
      #|http://users.example.com/users/1 => /users/1
      #|http://users.example.com:8080/users/1?verbose=true => /users/1
      #|HTTPS://users.example.com => /
      #|http://users.example.com?verbose=true => /
      #|* => *
      #|users.example.com:443 => users.example.com:443
      #|/? => /
      #|/a?b?c => /a
    ),
  )
}
