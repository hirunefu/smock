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

///|
/// A Mock name in Japanese with spaces, quotes, a backslash, a slash and an
/// emoji; one with each control character; and a target with a quote and a
/// backslash, which a request target may hold.
test "strings are escaped as JSON.stringify escapes them" {
  let out = [
    @log.mockoon_prefix(Some("ユーザー 一覧 \"v2\" C:\\mocks 😀 a/b")),
  ]
  for code in 0..<0x20 {
    out.push(@log.mockoon_prefix(Some("<\{code.unsafe_to_char()}>")))
  }
  out.push(
    @log.transaction_line(
      @log.mockoon_prefix(None),
      meth="GET",
      target="/a\"b\\c?d\"",
      status=404,
      at=example_time,
    ),
  )
  inspect(
    out.join("\n"),
    content=(
      #|{"app":"smock","environmentName":"ユーザー 一覧 \"v2\" C:\\mocks 😀 a/b",
      #|{"app":"smock","environmentName":"<\u0000>",
      #|{"app":"smock","environmentName":"<\u0001>",
      #|{"app":"smock","environmentName":"<\u0002>",
      #|{"app":"smock","environmentName":"<\u0003>",
      #|{"app":"smock","environmentName":"<\u0004>",
      #|{"app":"smock","environmentName":"<\u0005>",
      #|{"app":"smock","environmentName":"<\u0006>",
      #|{"app":"smock","environmentName":"<\u0007>",
      #|{"app":"smock","environmentName":"<\b>",
      #|{"app":"smock","environmentName":"<\t>",
      #|{"app":"smock","environmentName":"<\n>",
      #|{"app":"smock","environmentName":"<\u000b>",
      #|{"app":"smock","environmentName":"<\f>",
      #|{"app":"smock","environmentName":"<\r>",
      #|{"app":"smock","environmentName":"<\u000e>",
      #|{"app":"smock","environmentName":"<\u000f>",
      #|{"app":"smock","environmentName":"<\u0010>",
      #|{"app":"smock","environmentName":"<\u0011>",
      #|{"app":"smock","environmentName":"<\u0012>",
      #|{"app":"smock","environmentName":"<\u0013>",
      #|{"app":"smock","environmentName":"<\u0014>",
      #|{"app":"smock","environmentName":"<\u0015>",
      #|{"app":"smock","environmentName":"<\u0016>",
      #|{"app":"smock","environmentName":"<\u0017>",
      #|{"app":"smock","environmentName":"<\u0018>",
      #|{"app":"smock","environmentName":"<\u0019>",
      #|{"app":"smock","environmentName":"<\u001a>",
      #|{"app":"smock","environmentName":"<\u001b>",
      #|{"app":"smock","environmentName":"<\u001c>",
      #|{"app":"smock","environmentName":"<\u001d>",
      #|{"app":"smock","environmentName":"<\u001e>",
      #|{"app":"smock","environmentName":"<\u001f>",
      #|{"app":"smock","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/a\"b\\c","requestProxied":false,"responseStatus":404,"timestamp":"2026-10-31T09:00:01.250Z"}
    ),
  )
}
