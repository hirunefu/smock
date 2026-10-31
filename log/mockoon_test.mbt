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
