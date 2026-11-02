///|
/// `async/fs` does not expose opening with O_NOFOLLOW or constructing a File
/// from a descriptor. This helper only opens and validates the lock file;
/// locking uses the same native implementation as async/fs File::try_lock.
#borrow(path)
extern "C" fn open_lock_ffi(path : Bytes) -> Int32 = "moon_binstall_open_lock"

///|
#borrow(path)
extern "C" fn lock_matches_ffi(fd : Int32, path : Bytes) -> Bool = "moon_binstall_lock_matches"

///|
extern "C" fn try_lock_ffi(fd : Int32, exclusive : Bool) -> Int32 = "moonbitlang_async_try_lock_file"

///|
extern "C" fn lock_busy_ffi(err : Int32) -> Bool = "moonbitlang_async_errno_is_lock_violation"

///|
extern "C" fn close_lock_ffi(fd : Int32) -> Int32 = "close"

///|
async fn acquire_install_lock(
  bin_dir : String,
  timeout_seconds : Int32,
  on_wait? : async () -> Unit,
) -> Int32 {
  let path = bin_dir + "/.moon-binstall.lock"
  guard !path.contains("\u0000") else { abort_fs("invalid lock path") }
  let path_bytes = @utf8.encode(path + "\u0000")
  let fd = open_lock_ffi(path_bytes)
  if fd < 0 {
    let reason = @os_error.get_errno().to_string()
    abort_fs("cannot safely open install lock \{path}: \{reason}")
  }
  let mut acquired = false
  defer (if !acquired { ignore(close_lock_ffi(fd)) })
  async fn wait_for_lock() -> Unit {
    let mut notified = false
    while true {
      if try_lock_ffi(fd, true) >= 0 {
        return
      }
      let err = @os_error.get_errno()
      guard lock_busy_ffi(err) else {
        abort_fs("cannot acquire install lock \{path}: \{err}")
      }
      if !notified {
        match on_wait {
          Some(notify) => notify()
          None => ()
        }
        notified = true
      }
      @async.sleep(50)
    }
  }
  let result = if timeout_seconds == 0 {
    if try_lock_ffi(fd, true) >= 0 {
      Some(())
    } else {
      let err = @os_error.get_errno()
      guard lock_busy_ffi(err) else {
        abort_fs("cannot acquire install lock \{path}: \{err}")
      }
      None
    }
  } else {
    @async.with_timeout_opt(timeout_seconds * 1000, wait_for_lock)
  }
  guard result is Some(_) else {
    abort_fs(
      "timed out waiting for install lock \{path}; retry after the other install finishes",
    )
  }
  guard lock_matches_ffi(fd, path_bytes) else {
    abort_fs("install lock changed while acquiring it: \{path}")
  }
  acquired = true
  fd
}
