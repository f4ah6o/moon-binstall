///|
pub struct Options {
  pkg : Package
  directory : String?
  dry_run : Bool
  force : Bool
}

///|
pub fn usage() -> String {
  let msg = #|moon-binstall — install checksum-verified MoonBit binaries from GitHub Releases
  #|
  #|Usage:
  #|  moon-binstall install <owner/repo[@tag]> [--bin-dir DIR] [--force] [--dry-run]
  #|  moon-binstall <owner/repo[@tag]> [--bin-dir DIR] [--force] [--dry-run]
  #|  moon-binstall --help
  #|  moon binstall <owner/repo[@tag]> [--bin-dir DIR] [--force] [--dry-run]
  #|  moon binstall --help
  #|
  #|Aliases: turtles, hotpath, dsh
  #|Environment: MOON_BINSTALL_DIR (default $HOME/.local/bin)
  #|
  #|Requires: curl, macOS or Linux; SHA-256 digest in GitHub release metadata.
  #|hotpath installs the optional hotpath-report example binary, not the library.
  msg
}

///|
pub fn parse_options(argv : ArrayView[String]) -> Options raise {
  let mut coordinate = ""
  let mut directory : String? = None
  let mut dry_run = false
  let mut force = false
  let mut idx = 0
  while idx < argv.length() {
    let arg = argv[idx]
    match arg {
      "install" if idx == 0 => ()
      "--dry-run" => dry_run = true
      "--force" => force = true
      "--bin-dir" => {
        idx = idx + 1
        guard idx < argv.length() && argv[idx] != "" else {
          fail("--bin-dir requires a directory")
        }
        directory = Some(argv[idx])
      }
      _ => {
        guard !arg.has_prefix("-") && coordinate == "" else {
          fail("unrecognized or duplicate argument: \{arg}")
        }
        coordinate = arg
      }
    }
    idx = idx + 1
  }
  guard coordinate != "" else { fail("missing repository coordinate") }
  { pkg: parse_package(coordinate), directory, dry_run, force }
}

///|
async fn require_platform() -> String {
  let (os_status, os_out) = @process.collect_stdout("uname", ["-s"])
  guard os_status == 0 else { fail("uname -s failed") }
  let (cpu_status, cpu_out) = @process.collect_stdout("uname", ["-m"])
  guard cpu_status == 0 else { fail("uname -m failed") }
  platform_key(os_out.text().trim().to_owned(), cpu_out.text().trim().to_owned())
}

///|
fn target_directory(dir_override : String?) -> String raise {
  match dir_override {
    Some(dir) => {
      guard dir != "" && dir.has_prefix("/") else {
        fail("--bin-dir must be an absolute path")
      }
      dir
    }
    None =>
      match @env.get_env_var("MOON_BINSTALL_DIR") {
        Some(dir) => {
          guard dir != "" && dir.has_prefix("/") else {
            fail("MOON_BINSTALL_DIR must be an absolute path")
          }
          dir
        }
        None =>
          match @env.get_env_var("HOME") {
            Some(home) => home + "/.local/bin"
            None => fail("HOME is not set; provide --bin-dir")
          }
      }
  }
}

///|
/// Fail if curl refuses the transfer, rather than treating a 404 body as a
/// binary. Keep every request HTTPS, redirect only to HTTPS, and bound time.
async fn download(url : String, path : String) -> Unit {
  let args = [
    "--fail", "--silent", "--show-error", "--location",
    "--proto", "=https", "--proto-redir", "=https",
    "--max-redirs", "5",
    "--connect-timeout", "15", "--max-time", "300",
    "--output", path, url,
  ]
  let status = @process.run("curl", args)
  guard status == 0 else { fail("curl download failed (exit \{status})") }
}

///|
async fn verify_digest(path : String, expected : String) -> Unit {
  let bytes = @fs.read_file(path).binary()
  let actual = "sha256:" + @crypto.bytes_to_hex_string(@crypto.sha256(bytes))
  guard actual == expected else {
    fail("SHA-256 verification failed: expected \{expected}, got \{actual}")
  }
}

///|
pub async fn install(config : Options) -> Unit {
  let target = require_platform()
  let pkg = config.pkg
  let api = release_url(pkg)
  let (code, body) = @process.collect_stdout("curl", [
    "--fail", "--silent", "--show-error", "--location",
    "--proto", "=https", "--proto-redir", "=https",
    "--header", "Accept: application/vnd.github+json",
    "--header", "User-Agent: moon-binstall/0.1",
    "--connect-timeout", "15", "--max-time", "30", api,
  ])
  guard code == 0 else {
    fail("GitHub release lookup failed (curl exit \{code}): \{api}")
  }
  let release = resolve_release(body.text(), pkg, target)
  let bin_dir = target_directory(config.directory)
  let destination = bin_dir + "/" + pkg.binary
  println("Resolved \{pkg.owner}/\{pkg.repo}@\{release.tag}: \{release.name}")
  if config.dry_run {
    println("Would install \{release.url} -> \{destination}")
    return
  }
  @fs.mkdir(bin_dir, recursive=true, allow_exist=true)
  guard !@fs.exists(destination) || config.force else {
    fail("already exists: \{destination} (use --force to replace)")
  }
  // Avoid redirecting writes through a symlink, even with --force.
  if @fs.exists(destination) {
    guard @fs.kind(destination, follow_symlink=false) is Regular else {
      fail("refusing to replace a non-regular file: \{destination}")
    }
  }
  let staging = bin_dir + "/.\{pkg.binary}.moon-binstall.part"
  guard !@fs.exists(staging) else {
    fail("staging file exists (concurrent or interrupted install): \{staging}")
  }
  defer (@fs.remove(staging) catch { _ => () })
  download(release.url, staging)
  verify_digest(staging, release.digest)
  @fs.chmod(staging, 0o755)
  @fs.rename(staging, destination, replace=config.force)
  println("Installed \{destination}")
}

///|
pub async fn execute(argv : ArrayView[String]) -> Int {
  if argv.length() == 0 || (argv.length() == 1 &&
    (argv[0] == "--help" || argv[0] == "-h" || argv[0] == "help")) {
    println(usage())
    return 0
  }
  if argv.length() == 1 && argv[0] == "--version" {
    println("moon-binstall 0.1.2")
    return 0
  }
  let config = parse_options(argv)
  install(config)
  0
}
