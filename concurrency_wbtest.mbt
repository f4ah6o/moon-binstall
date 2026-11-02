///|
/// The newer update holds the destination lock at its download barrier. The
/// older concurrent update must decide again after the newer receipt is saved.
async test "concurrent updates recheck the receipt under the destination lock" {
  let root = @fs.tmpdir(prefix="moon-binstall-race")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let bin_dir = root + "/bin"
  let initial = make_github_release_transport(
    root, "v1.0.0", "1.0.0", "initial\n",
  )
  let older = make_github_release_transport(root, "v1.1.0", "1.1.0", "older\n")
  let newer = make_github_release_transport(root, "v1.2.0", "1.2.0", "newer\n")
  install_many_using(github_options(bin_dir, "v1.0.0", false), Fixture(initial))
  let reached = @cond_var.Cond()
  let release_gate = @cond_var.Cond()
  let waiting = @cond_var.Cond()
  @async.with_task_group(group => {
    let first = group.spawn(() => {
      install_many_using(
        github_options(bin_dir, "v1.2.0", false),
        PausedFixture(newer, () => {
          reached.signal()
          release_gate.wait()
        }),
      )
    })
    @async.with_timeout(10000, () => reached.wait())
    let blocked = try {
      let fd = acquire_install_lock(bin_dir, 0)
      ignore(close_lock_ffi(fd))
      false
    } catch {
      InstallError(stage=Filesystem, ..) => true
      _ => false
    }
    assert_true(blocked)
    let second = group.spawn(() => {
      try {
        install_many_using(
          github_options(bin_dir, "v1.1.0", false),
          WaitingFixture(older, () => waiting.signal()),
        )
        false
      } catch {
        InstallError(stage=Destination, reason~, ..) =>
          reason.contains("older than")
        _ => false
      }
    })
    @async.with_timeout(10000, () => waiting.wait())
    release_gate.signal()
    first.wait()
    assert_true(second.wait())
  })
  assert_eq(@fs.read_file(bin_dir + "/tool").text(), "newer\n")
  let receipt = read_receipt_file(receipt_path(bin_dir, "tool"))
  guard receipt is Some(value) else { fail("missing receipt") }
  assert_eq(value.tag, "v1.2.0")
  assert_eq(value.binary_digest, file_sha256(bin_dir + "/tool"))
}

///|
/// A separate process holds the OS lock until its stdin closes. The test
/// process runs the real fixture-backed installer against the same inode.
async test "process lock timeout preserves files and other destinations proceed" {
  let root = @fs.tmpdir(prefix="moon-binstall-process-lock")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let bin_dir = root + "/bin"
  let alias_dir = root + "/alias_dir"
  let initial = make_github_release_transport(
    root, "v1.0.0", "1.0.0", "initial\n",
  )
  let newer = make_github_release_transport(root, "v1.1.0", "1.1.0", "newer\n")
  install_many_using(github_options(bin_dir, "v1.0.0", false), Fixture(initial))
  @fs.symlink(alias_dir, target=bin_dir)
  let receipt_file = receipt_path(bin_dir, "tool")
  let before_receipt = @fs.read_file(receipt_file).text()
  let before_binary = @fs.read_file(bin_dir + "/tool").text()
  let lock_path = bin_dir + "/.moon-binstall.lock"
  let script = "import fcntl,sys; f=open(sys.argv[1],'r+'); fcntl.flock(f,fcntl.LOCK_EX); print('locked',flush=True); sys.stdin.buffer.read(1)"
  @async.with_task_group(group => {
    let (reader, output) = @process.read_from_process()
    let (input, writer) = @process.write_to_process()
    defer reader.close()
    let holder = @process.spawn(
      group,
      "python3",
      ["-c", script, lock_path],
      stdin=input,
      stdout=output,
    )
    guard reader.read_until("\n") is Some("locked") else {
      fail("holder did not acquire lock")
    }
    let options = parse_batch_options([
      "acme/tool@v1.1.0", "--target", "linux-x86_64", "--bin-dir", alias_dir, "--lock-timeout",
      "0",
    ])
    let timed_out = try {
      install_many_using(options, Fixture(newer))
      false
    } catch {
      InstallError(stage=Filesystem, reason~, ..) =>
        reason.contains("timed out")
      _ => false
    }
    assert_true(timed_out)
    assert_eq(@fs.read_file(bin_dir + "/tool").text(), before_binary)
    assert_eq(@fs.read_file(receipt_file).text(), before_receipt)
    assert_true(@fs.exists(lock_path))
    // A separate directory is not held by this process.
    install_many_using(
      github_options(root + "/other", "v1.1.0", false),
      Fixture(newer),
    )
    assert_eq(@fs.read_file(root + "/other/tool").text(), "newer\n")
    // A killed holder leaves the file behind but the OS releases its lock.
    assert_eq(@process.run("/bin/kill", ["-KILL", holder.pid.to_string()]), 0)
    assert_eq(holder.wait(), -9)
    writer.close()
    install_many_using(github_options(bin_dir, "v1.1.0", false), Fixture(newer))
  })
  assert_eq(@fs.read_file(bin_dir + "/tool").text(), "newer\n")
  let receipt = read_receipt_file(receipt_file)
  guard receipt is Some(value) else { fail("missing receipt") }
  assert_eq(value.tag, "v1.1.0")
  assert_eq(value.binary_digest, file_sha256(bin_dir + "/tool"))
}

///|
async test "unsafe lock entries are refused" {
  let root = @fs.tmpdir(prefix="moon-binstall-lock-entry")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let victim = root + "/victim"
  let lock_path = root + "/.moon-binstall.lock"
  @fs.write_file(victim, "untouched")
  @fs.symlink(lock_path, target=victim)
  let rejected = try {
    let fd = acquire_install_lock(root, 0)
    ignore(close_lock_ffi(fd))
    false
  } catch {
    InstallError(stage=Filesystem, ..) => true
    _ => false
  }
  assert_true(rejected)
  assert_eq(@fs.read_file(victim).text(), "untouched")
  @fs.remove(lock_path)
  @fs.mkdir(lock_path)
  let rejected_dir = try {
    let fd = acquire_install_lock(root, 0)
    ignore(close_lock_ffi(fd))
    false
  } catch {
    InstallError(stage=Filesystem, ..) => true
    _ => false
  }
  assert_true(rejected_dir)
  @fs.rmdir(lock_path)
  assert_eq(@process.run("mkfifo", [lock_path]), 0)
  let rejected_fifo = try {
    let fd = acquire_install_lock(root, 0)
    ignore(close_lock_ffi(fd))
    false
  } catch {
    InstallError(stage=Filesystem, ..) => true
    _ => false
  }
  assert_true(rejected_fifo)
  @fs.remove(lock_path)
  assert_eq(@process.run("ln", [victim, lock_path]), 0)
  let rejected_hardlink = try {
    let fd = acquire_install_lock(root, 0)
    ignore(close_lock_ffi(fd))
    false
  } catch {
    InstallError(stage=Filesystem, ..) => true
    _ => false
  }
  assert_true(rejected_hardlink)
  assert_eq(@fs.read_file(victim).text(), "untouched")
}

///|
async test "dry run does not create or modify lock files" {
  let root = @fs.tmpdir(prefix="moon-binstall-lock-dry")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let bin_dir = root + "/bin"
  let initial = make_github_release_transport(
    root, "v1.0.0", "1.0.0", "initial\n",
  )
  install_many_using(github_dry_options(bin_dir, "v1.0.0"), Fixture(initial))
  assert_true(!@fs.exists(bin_dir))
  install_many_using(github_options(bin_dir, "v1.0.0", false), Fixture(initial))
  let lock = bin_dir + "/.moon-binstall.lock"
  let lock_time = @fs.mtime(lock)
  let directory_time = @fs.mtime(bin_dir)
  let receipt_file = receipt_path(bin_dir, "tool")
  let receipt_time = @fs.mtime(receipt_file)
  let binary_time = @fs.mtime(bin_dir + "/tool")
  install_many_using(github_dry_options(bin_dir, "v1.0.0"), Fixture(initial))
  assert_eq(@fs.mtime(lock), lock_time)
  assert_eq(@fs.mtime(bin_dir), directory_time)
  assert_eq(@fs.mtime(receipt_file), receipt_time)
  assert_eq(@fs.mtime(bin_dir + "/tool"), binary_time)
}

///|
test "lock timeout accepts bounded integer seconds" {
  for value in ["", "-1", "+1", "1.5", "3601", "999999999999999999999"] {
    let rejected = try {
      ignore(parse_batch_options(["acme/tool", "--lock-timeout", value]))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
  assert_eq(
    parse_batch_options(["acme/tool", "--lock-timeout", "0"]).lock_timeout,
    0,
  )
  assert_eq(
    parse_batch_options(["acme/tool", "--lock-timeout", "3600"]).lock_timeout,
    3600,
  )
  assert_true(
    try {
      ignore(
        parse_batch_options([
          "acme/tool", "--lock-timeout", "0", "--lock-timeout", "1",
        ]),
      )
      false
    } catch {
      _ => true
    },
  )
}

///|
async fn wait_for_worker_line(
  reader : @process.ReadFromProcess,
  wanted : String,
) -> Unit {
  @async.with_timeout(10000, () => {
    while reader.read_until("\n") is Some(line) {
      if line == wanted {
        return
      }
    }
    fail("worker exited before \{wanted}")
  })
}

///|
async test "two installer processes serialize and reject a stale update" {
  let root = @fs.tmpdir(prefix="moon-binstall-two-installers")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let initial = make_github_release_transport(
    root, "v1.0.0", "1.0.0", "initial\n",
  )
  install_many_using(
    github_options(root + "/bin", "v1.0.0", false),
    Fixture(initial),
  )
  let program = @env.args()[0]
  @async.with_task_group(group => {
    let (new_reader, new_output) = @process.read_from_process()
    let (new_input, new_writer) = @process.write_to_process()
    defer new_reader.close()
    let first = @process.spawn(
      group,
      program,
      ["concurrency_worker_wbtest.mbt:0-1"],
      stdin=new_input,
      stdout=new_output,
      extra_env={
        "MOON_BINSTALL_TEST_ROOT": root,
        "MOON_BINSTALL_TEST_TAG": "v1.2.0",
      },
    )
    wait_for_worker_line(new_reader, "LOCK_HELD")
    let (old_reader, old_output) = @process.read_from_process()
    defer old_reader.close()
    let second = @process.spawn(
      group,
      program,
      ["concurrency_worker_wbtest.mbt:0-1"],
      stdout=old_output,
      extra_env={
        "MOON_BINSTALL_TEST_ROOT": root,
        "MOON_BINSTALL_TEST_TAG": "v1.1.0",
      },
    )
    wait_for_worker_line(old_reader, "LOCK_WAITING")
    let busy = try {
      let fd = acquire_install_lock(root + "/bin", 0)
      ignore(close_lock_ffi(fd))
      false
    } catch {
      InstallError(stage=Filesystem, ..) => true
      _ => false
    }
    assert_true(busy)
    new_writer.write("x")
    new_writer.close()
    wait_for_worker_line(new_reader, "WORKER_DONE")
    assert_eq(first.wait(), 0)
    wait_for_worker_line(old_reader, "WORKER_DONE")
    assert_eq(second.wait(), 0)
  })
  assert_eq(@fs.read_file(root + "/bin/tool").text(), "newer\n")
  guard read_receipt_file(receipt_path(root + "/bin", "tool")) is Some(receipt) else {
    fail("missing receipt")
  }
  assert_eq(receipt.tag, "v1.2.0")
  assert_eq(receipt.binary_digest, file_sha256(root + "/bin/tool"))
}

///|
async test "local asset installation participates in the destination lock" {
  let root = @fs.tmpdir(prefix="moon-binstall-local-lock")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let bin_dir = root + "/bin"
  @fs.mkdir(bin_dir)
  let asset = root + "/asset"
  @fs.write_file(asset, "new binary\n")
  let digest = fixture_digest(asset)
  @fs.write_file(bin_dir + "/tool", "original\n")
  let lock = acquire_install_lock(bin_dir, 0)
  let result = @async.with_timeout_opt(100, () => {
    install_from_asset_file(asset, digest, "bin", None, "tool", bin_dir, true)
  })
  assert_true(result is None)
  assert_eq(@fs.read_file(bin_dir + "/tool").text(), "original\n")
  ignore(close_lock_ffi(lock))
  install_from_asset_file(asset, digest, "bin", None, "tool", bin_dir, true)
  assert_eq(@fs.read_file(bin_dir + "/tool").text(), "new binary\n")
}

///|
/// Count destination entries other than the persistent cooperative lock.
async fn count_installed_entries(path : String) -> Int32 {
  let entries = @fs.readdir(path, include_hidden=true)
  assert_true(entries.contains(".moon-binstall.lock"))
  entries.length() - 1
}

///|
async test "self update uses the same lock as ordinary installation" {
  let root = @fs.tmpdir(prefix="moon-binstall-self-lock")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let bin_dir = root + "/bin"
  @fs.mkdir(bin_dir)
  let asset = root + "/self.bin"
  @fs.write_file(asset, "self update\n")
  let digest = fixture_digest(asset)
  let url = "https://github.com/f4ah6o/moon-binstall/releases/download/v1.0.0/moon-binstall-linux-x86_64"
  let api = "https://api.github.com/repos/f4ah6o/moon-binstall/releases/tags/v1.0.0"
  let payload = "{\"tag_name\":\"v1.0.0\",\"assets\":[{\"name\":\"moon-binstall-linux-x86_64\",\"browser_download_url\":\"\{url}\",\"digest\":\"\{digest}\"}]}"
  let fixture = FixtureTransport::{
    responses: [(api, payload)],
    files: [(url, asset)],
    failures: [],
  }
  let options = parse_batch_options([
    "f4ah6o/moon-binstall@v1.0.0", "--target", "linux-x86_64", "--bin-dir", bin_dir,
    "--lock-timeout", "0",
  ])
  let plan = resolve_package_plan(
    options.coordinates[0],
    options,
    "linux-x86_64",
    root,
    0,
    Fixture(fixture),
  )
  assert_true(is_self_update(plan))
  let lock = acquire_install_lock(bin_dir, 0)
  let rejected = try {
    install_many_using(options, Fixture(fixture))
    false
  } catch {
    InstallError(stage=Filesystem, reason~, ..) => reason.contains("timed out")
    _ => false
  }
  assert_true(rejected)
  assert_true(!@fs.exists(bin_dir + "/moon-binstall"))
  ignore(close_lock_ffi(lock))
  install_many_using(options, Fixture(fixture))
  assert_eq(@fs.read_file(bin_dir + "/moon-binstall").text(), "self update\n")
}
