// The reset connection Fault: closing a connection sends an RST instead of
// a FIN. Its C, in reset.c, is the one function ADR 0001 allows besides
// OpenSSL.

///|
/// Sets SO_LINGER with a zero timeout on the socket `fd`. Returns 0, or the
/// errno of the failure.
extern "C" fn reset_on_close_ffi(fd : Int) -> Int = "smock_reset_on_close"

///|
/// Makes closing `conn` reset the connection with an RST, instead of ending
/// it with a FIN, and returns whether it could. When it cannot, it logs the
/// failure as an error, and closing `conn` sends a FIN as usual.
fn reset_on_close(conn : @socket.Tcp, logger : @log.Logger) -> Bool {
  let errno = reset_on_close_ffi(conn.fd())
  if errno == 0 {
    return true
  }
  logger.error("cannot reset the connection", fields={
    "error": Json::string(
      @os_error.OSError(errno, context="setsockopt(SO_LINGER)").to_string(),
    ),
  })
  false
}
