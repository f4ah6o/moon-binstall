///|
/// The install stage where a failure was observed. Each stage renders as a
/// stable `[code]` in user-facing error output, so the code stays meaningful
/// even when the wording of a message changes.
pub enum Stage {
  Coordinate
  Resolve
  Transfer
  Digest
  Archive
  Destination
  Compat
  Filesystem
}

///|
/// Stable machine-readable code for a stage, shown as `error[code]`.
pub fn stage_code(stage : Stage) -> String {
  match stage {
    Coordinate => "coordinate"
    Resolve => "resolve"
    Transfer => "transport"
    Digest => "digest"
    Archive => "archive"
    Destination => "destination"
    Compat => "compat"
    Filesystem => "filesystem"
  }
}

///|
/// A classified, user-facing failure: the attempted operation and the object
/// it acted on, the observed reason, and the next actionable step. Source
/// locations are never part of this rendering.
pub(all) suberror InstallError {
  InstallError(
    stage~ : Stage,
    what~ : String,
    target~ : String,
    reason~ : String,
    action~ : String,
  )
}

///|
/// Raise a classified install error. `target` names the object the
/// operation acted on (a coordinate, URL or path; "" when there is none);
/// `action` is the next actionable step shown to the user.
fn[T] abort_install(
  stage : Stage,
  what : String,
  target : String,
  reason : String,
  action~ : String = "",
) -> T raise InstallError {
  raise InstallError(stage~, what~, target~, reason~, action~)
}

///|
/// Message-only shims matching `fail`'s signature, for call sites whose
/// operation and object are already embedded in the reason string.
fn[T] abort_args(reason : String) -> T raise InstallError {
  abort_install(
    Coordinate, "parse command line arguments", "", reason,
    action="run 'moon binstall --help' for usage",
  )
}

///|
fn[T] abort_resolve(reason : String) -> T raise InstallError {
  abort_install(
    Resolve, "resolve the install plan", "", reason,
    action="check the coordinate and try again",
  )
}

///|
fn[T] abort_dest(reason : String) -> T raise InstallError {
  abort_install(Destination, "check the destination", "", reason)
}

///|
fn[T] abort_fs(reason : String) -> T raise InstallError {
  abort_install(
    Filesystem, "access the filesystem", "", reason,
    action="check the path and permissions, then retry",
  )
}

///|
fn[T] abort_digest(reason : String) -> T raise InstallError {
  abort_install(
    Digest, "verify the download", "", reason,
    action="nothing was installed; retry the install",
  )
}

///|
fn[T] abort_compat_msg(reason : String) -> T raise InstallError {
  abort_install(Compat, "verify runtime compatibility", "", reason)
}

///|
/// Render a classified error for stderr: operation, object, observed reason
/// and next step. No source file/line or internal error type is included.
pub fn render_error(error : InstallError) -> String {
  match error {
    InstallError(stage~, what~, target~, reason~, action~) => {
      let lines : Array[String] = [
        "moon-binstall: error[\{stage_code(stage)}]: \{what}",
      ]
      if target != "" {
        lines.push("  target: \{target}")
      }
      lines.push("  reason: \{reason}")
      if action != "" {
        lines.push("  action: \{action}")
      }
      lines.join("\n")
    }
  }
}

///|
/// Debug rendering behind MOON_BINSTALL_DEBUG: every classified field,
/// never credentials or response bodies.
pub impl Show for InstallError with output(
  self : InstallError,
  logger : &Logger,
) -> Unit {
  match self {
    InstallError(stage~, what~, target~, reason~, action~) =>
      logger.write_string(
        "InstallError(stage=\{stage_code(stage)}, what=\{what}, target=\{target}, reason=\{reason}, action=\{action})",
      )
  }
}

///|
/// `fail()` embeds the source location as `<loc> FAILED: <msg>`; strip that
/// wrapper for the plain user-facing message.
fn strip_failure_prefix(message : String) -> String {
  match message.find(" FAILED: ") {
    Some(index) => message[index + 8:].to_owned()
    None => message
  }
}

///|
/// Report any failure to stderr and return the process exit code. Classified
/// errors render their stage code, operation, target, reason and action;
/// other failures render as a single sanitized line. The raw error (with
/// source locations) is only shown when MOON_BINSTALL_DEBUG is set.
pub fn report_error(error : Error) -> Int {
  let debug = match @env.get_env_var("MOON_BINSTALL_DEBUG") {
    Some(value) => value != ""
    None => false
  }
  match error {
    InstallError(..) as err => {
      eprintln(render_error(err))
      if debug {
        eprintln("moon-binstall: debug: \{err}")
      }
    }
    Failure(message) => {
      eprintln("moon-binstall: error: \{strip_failure_prefix(message)}")
      if debug {
        eprintln("moon-binstall: debug: \{error}")
      }
    }
    _ => eprintln("moon-binstall: error: \{error}")
  }
  1
}
