// gRPC's status codes: the outcome of a call, which a server sends in
// `grpc-status` as a decimal number, and which smock's users write by
// name (https://grpc.github.io/grpc/core/md_doc_statuscodes.html).

///|
/// A gRPC status code. Each has its number, sent in `grpc-status`, and its
/// name, such as `NOT_FOUND`, as gRPC's documentation and Definition files
/// write it.
#derive(Eq, Debug)
pub(all) enum Status {
  /// 0, `OK`: the call succeeded.
  Ok
  /// 1, `CANCELLED`: the call was cancelled, usually by the caller.
  Cancelled
  /// 2, `UNKNOWN`: an unknown error.
  Unknown
  /// 3, `INVALID_ARGUMENT`: the caller gave an invalid argument.
  InvalidArgument
  /// 4, `DEADLINE_EXCEEDED`: the deadline expired before the call ended.
  DeadlineExceeded
  /// 5, `NOT_FOUND`: something the call asked for was not found.
  NotFound
  /// 6, `ALREADY_EXISTS`: what the call tried to create already exists.
  AlreadyExists
  /// 7, `PERMISSION_DENIED`: the caller may not do this.
  PermissionDenied
  /// 8, `RESOURCE_EXHAUSTED`: a resource, such as a quota, ran out.
  ResourceExhausted
  /// 9, `FAILED_PRECONDITION`: the system is not in the state the call
  /// needs.
  FailedPrecondition
  /// 10, `ABORTED`: the call was aborted, as by a concurrency conflict.
  Aborted
  /// 11, `OUT_OF_RANGE`: the call went past a valid range.
  OutOfRange
  /// 12, `UNIMPLEMENTED`: the method is not implemented or not supported.
  Unimplemented
  /// 13, `INTERNAL`: an internal error.
  Internal
  /// 14, `UNAVAILABLE`: the service is unavailable for now.
  Unavailable
  /// 15, `DATA_LOSS`: data was lost or corrupted.
  DataLoss
  /// 16, `UNAUTHENTICATED`: the caller has no valid credentials.
  Unauthenticated
}

///|
/// Every status, by its code: `statuses[n]` has the code `n`.
let statuses : FixedArray[Status] = [
  Ok,
  Cancelled,
  Unknown,
  InvalidArgument,
  DeadlineExceeded,
  NotFound,
  AlreadyExists,
  PermissionDenied,
  ResourceExhausted,
  FailedPrecondition,
  Aborted,
  OutOfRange,
  Unimplemented,
  Internal,
  Unavailable,
  DataLoss,
  Unauthenticated,
]

///|
/// The status's code, from 0 for `OK` to 16 for `UNAUTHENTICATED`, which
/// `grpc-status` carries in decimal.
pub fn Status::code(self : Status) -> Int32 {
  match self {
    Ok => 0
    Cancelled => 1
    Unknown => 2
    InvalidArgument => 3
    DeadlineExceeded => 4
    NotFound => 5
    AlreadyExists => 6
    PermissionDenied => 7
    ResourceExhausted => 8
    FailedPrecondition => 9
    Aborted => 10
    OutOfRange => 11
    Unimplemented => 12
    Internal => 13
    Unavailable => 14
    DataLoss => 15
    Unauthenticated => 16
  }
}

///|
/// The status's name, as gRPC's documentation writes it, such as
/// `NOT_FOUND`.
pub fn Status::name(self : Status) -> String {
  match self {
    Ok => "OK"
    Cancelled => "CANCELLED"
    Unknown => "UNKNOWN"
    InvalidArgument => "INVALID_ARGUMENT"
    DeadlineExceeded => "DEADLINE_EXCEEDED"
    NotFound => "NOT_FOUND"
    AlreadyExists => "ALREADY_EXISTS"
    PermissionDenied => "PERMISSION_DENIED"
    ResourceExhausted => "RESOURCE_EXHAUSTED"
    FailedPrecondition => "FAILED_PRECONDITION"
    Aborted => "ABORTED"
    OutOfRange => "OUT_OF_RANGE"
    Unimplemented => "UNIMPLEMENTED"
    Internal => "INTERNAL"
    Unavailable => "UNAVAILABLE"
    DataLoss => "DATA_LOSS"
    Unauthenticated => "UNAUTHENTICATED"
  }
}

///|
/// Shows the status by its name, such as `NOT_FOUND`.
pub impl Show for Status with fn output(self, logger) {
  logger.write_string(self.name())
}

///|
/// The status whose code is `code`, or `None` for a number outside 0 to 16.
pub fn Status::from_code(code : Int32) -> Status? {
  if code >= 0 && code < statuses.length() {
    Some(statuses[code])
  } else {
    None
  }
}

///|
/// The status whose name is `name`, exactly as `Status::name` gives it, or
/// `None` for any other text.
pub fn Status::from_name(name : String) -> Status? {
  for status in statuses {
    if status.name() == name {
      return Some(status)
    }
  }
  None
}
