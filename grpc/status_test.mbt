// gRPC's status codes through the module's public interface: each code's
// number and name, as gRPC's status code list gives them
// (https://grpc.github.io/grpc/core/md_doc_statuscodes.html), and both
// read back.

///|
test "the seventeen status codes have gRPC's numbers and names, in order" {
  let out = []
  for code in 0..<17 {
    guard @grpc.Status::from_code(code) is Some(status) else {
      fail("no status for \{code}")
    }
    out.push("\{status.code()} \{status}")
  }
  inspect(
    out.join("\n"),
    content=(
      #|0 OK
      #|1 CANCELLED
      #|2 UNKNOWN
      #|3 INVALID_ARGUMENT
      #|4 DEADLINE_EXCEEDED
      #|5 NOT_FOUND
      #|6 ALREADY_EXISTS
      #|7 PERMISSION_DENIED
      #|8 RESOURCE_EXHAUSTED
      #|9 FAILED_PRECONDITION
      #|10 ABORTED
      #|11 OUT_OF_RANGE
      #|12 UNIMPLEMENTED
      #|13 INTERNAL
      #|14 UNAVAILABLE
      #|15 DATA_LOSS
      #|16 UNAUTHENTICATED
    ),
  )
}

///|
test "a code outside 0 to 16 has no status" {
  debug_inspect(@grpc.Status::from_code(-1), content="None")
  debug_inspect(@grpc.Status::from_code(17), content="None")
}

///|
test "a status is found by its name, in upper case only" {
  for code in 0..<17 {
    guard @grpc.Status::from_code(code) is Some(status) else {
      fail("no status for \{code}")
    }
    assert_eq(@grpc.Status::from_name(status.name()), Some(status))
  }
  debug_inspect(@grpc.Status::from_name("NOT_FOUND"), content="Some(NotFound)")
  debug_inspect(@grpc.Status::from_name("not_found"), content="None")
  debug_inspect(@grpc.Status::from_name("NOTFOUND"), content="None")
  debug_inspect(@grpc.Status::from_name(""), content="None")
}

///|
test "a status's code is the decimal text grpc-status carries" {
  inspect(@grpc.Status::Internal.code().to_string(), content="13")
  inspect(@grpc.Status::Ok.code().to_string(), content="0")
}
