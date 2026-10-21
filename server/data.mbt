// The Admin API operations on Data buckets: listing the buckets of a Mock,
// and reading, setting and dropping the calling Session's copy of one. Each
// is scoped to the calling Session, named the way mocked requests name
// theirs, and a set and a drop that drops a copy are logged.

///|
/// Lists the buckets of a Mock, each with whether the calling Session holds
/// its own copy, without their values.
fn list_buckets(admin : Admin, call : Call) -> Reply {
  let session = admin.session(call.request)
  let buckets = admin.engine().list_data(mock=call.param("mock"), session~) catch {
      error => return admin.refused(error, session)
    }
  admin.json(200, {
    "data": Json::array(buckets.map(bucket => bucket_json(bucket, value=false))),
  })
}

///|
/// Reads one bucket of a Mock as the calling Session sees it: its copy, or
/// else the initial value.
fn read_bucket(admin : Admin, call : Call) -> Reply {
  let session = admin.session(call.request)
  let bucket = admin
    .engine()
    .read_data(mock=call.param("mock"), session~, bucket=call.param("bucket")) catch {
      error => return admin.refused(error, session)
    }
  admin.json(200, { "bucket": bucket_json(bucket, value=true) })
}

///|
/// Makes the value the body holds the calling Session's copy of one bucket
/// of a Mock, and logs it.
fn set_bucket(admin : Admin, call : Call) -> Reply {
  let session = admin.session(call.request)
  guard call.body is Some(value) else {
    return admin.error(
      400, "invalid_request", "the body must be the value to set the bucket to: any JSON value",
    )
  }
  let mock = call.param("mock")
  let name = call.param("bucket")
  let bucket = admin.engine().set_data(mock~, session~, bucket=name, value) catch {
      error => return admin.refused(error, session)
    }
  admin.logger.info("Data bucket set", fields={
    "mock": Json::string(mock),
    "session": session_json(session),
    "bucket": Json::string(name),
  })
  admin.json(200, { "bucket": bucket_json(bucket, value=true) })
}

///|
/// Drops the calling Session's copy of one bucket of a Mock, so that it
/// reads the initial value again, and logs it when there was a copy.
fn drop_bucket(admin : Admin, call : Call) -> Reply {
  let session = admin.session(call.request)
  let mock = call.param("mock")
  let name = call.param("bucket")
  let engine = admin.engine()
  let before = engine.read_data(mock~, session~, bucket=name) catch {
    error => return admin.refused(error, session)
  }
  let bucket = engine.drop_data(mock~, session~, bucket=name) catch {
    error => return admin.refused(error, session)
  }
  if before.written {
    admin.logger.info("Data bucket copy dropped", fields={
      "mock": Json::string(mock),
      "session": session_json(session),
      "bucket": Json::string(name),
    })
  }
  admin.json(200, { "bucket": bucket_json(bucket, value=true) })
}

///|
/// A bucket as the Admin API shows it: its name, its key and new keys, or
/// `null` for each when it is not keyed, whether the calling Session holds
/// its own copy, and, with `value`, what the Session reads.
fn bucket_json(bucket : @engine.SessionBucket, value~ : Bool) -> Json {
  let json : Map[String, Json] = {
    "name": Json::string(bucket.name),
    "key": match bucket.key {
      Some(key) => Json::string(key)
      None => Json::null()
    },
    "newKey": match bucket.new_key {
      Some(new_key) => Json::string(new_key.name())
      None => Json::null()
    },
    "written": Json::boolean(bucket.written),
  }
  if value {
    json["value"] = bucket.value
  }
  Json::object(json)
}
