///|
/// A receipt-less executable must be compared to the verified archive member,
/// not to the ZIP/TGZ container. Adoption never rewrites the executable.
async test "unmanaged archive binary is adopted without rewriting" {
  for format in ["zip", "tgz"] {
    let root = @fs.tmpdir(prefix="moon-binstall-adopt-\{format}")
    defer (@fs.rmdir(root, recursive=true) catch { _ => () })
    let bin_dir = root + "/bin"
    let destination = bin_dir + "/tool"
    @fs.mkdir(bin_dir)
    @fs.write_file(destination, "already-extracted\n")
    @fs.chmod(destination, 0o711)
    let mtime = @fs.mtime(destination)
    let ctime = @fs.ctime(destination)
    let transport = make_github_format_transport(
      root, "v1.2.3", "1.2.3", "already-extracted\n", format,
    )
    install_many_using(
      github_options(bin_dir, "v1.2.3", false),
      Fixture(transport),
    )
    assert_eq(@fs.read_file(destination).text(), "already-extracted\n")
    assert_eq(@fs.mtime(destination), mtime)
    assert_eq(@fs.ctime(destination), ctime)
    let receipt_file = receipt_path(bin_dir, "tool")
    let receipt = match read_receipt_file(receipt_file) {
      Some(value) => value
      None => abort("adopted binary must have a receipt")
    }
    assert_eq(receipt.binary_digest, file_sha256(destination))
    assert_eq(receipt.asset_digest, fixture_digest(transport.files[0].1))
    assert_true(receipt.asset_digest != receipt.binary_digest)
    let receipt_bytes = @fs.read_file(receipt_file).text()
    // Once adopted, the existing receipt enables a metadata-only skip.
    install_many_using(
      github_options(bin_dir, "v1.2.3", false),
      Fixture({ responses: transport.responses, files: [], failures: [], }),
    )
    assert_eq(@fs.read_file(receipt_file).text(), receipt_bytes)
    assert_eq(@fs.mtime(destination), mtime)
    assert_eq(@fs.ctime(destination), ctime)
    assert_eq(@fs.readdir(bin_dir, include_hidden=true).length(), 2)
    // Adoption also enables the next managed upgrade without --force.
    install_many_using(
      github_options(bin_dir, "v1.2.4", false),
      Fixture(
        make_github_format_transport(
          root, "v1.2.4", "1.2.4", "updated\n", format,
        ),
      ),
    )
    assert_eq(@fs.read_file(destination).text(), "updated\n")
  }
}

///|
/// Copying an archive to PATH does not make it the executable inside it,
/// even though the existing file matches GitHub's release asset digest.
async test "unmanaged archive bytes are not mistaken for an installed binary" {
  for format in ["zip", "tgz"] {
    let root = @fs.tmpdir(prefix="moon-binstall-container-\{format}")
    defer (@fs.rmdir(root, recursive=true) catch { _ => () })
    let bin_dir = root + "/bin"
    let destination = bin_dir + "/tool"
    let transport = make_github_format_transport(
      root, "v1.2.3", "1.2.3", "actual-executable\n", format,
    )
    @fs.mkdir(bin_dir)
    @fs.write_file(destination, @fs.read_file(transport.files[0].1).binary())
    let original_digest = file_sha256(destination)
    let rejected = try {
      install_many_using(
        github_options(bin_dir, "v1.2.3", false),
        Fixture(transport),
      )
      false
    } catch {
      InstallError(stage=Destination, action~, ..) => action.contains("--force")
      _ => false
    }
    assert_true(rejected)
    assert_eq(file_sha256(destination), original_digest)
    assert_true(!@fs.exists(receipt_path(bin_dir, "tool")))
    assert_eq(@fs.readdir(bin_dir, include_hidden=true).length(), 1)
  }
}

///|
async test "unmanaged archive dry run defers comparison without downloading" {
  for format in ["zip", "tgz"] {
    let root = @fs.tmpdir(prefix="moon-binstall-adopt-dry-\{format}")
    defer (@fs.rmdir(root, recursive=true) catch { _ => () })
    let bin_dir = root + "/bin"
    let destination = bin_dir + "/tool"
    @fs.mkdir(bin_dir)
    @fs.write_file(destination, "existing\n")
    let mtime = @fs.mtime(destination)
    let transport = make_github_format_transport(
      root, "v1.2.3", "1.2.3", "existing\n", format,
    )
    let metadata_only = Fixture({
      responses: transport.responses,
      files: [],
      failures: [],
    })
    let options = github_dry_options(bin_dir, "v1.2.3")
    let plan = resolve_package_plan(
      options.coordinates[0],
      options,
      "linux-x86_64",
      root,
      0,
      metadata_only,
    )
    assert_true(decide_install(plan, bin_dir, false) is VerifyExisting(_))
    install_many_using(options, metadata_only)
    assert_eq(@fs.read_file(destination).text(), "existing\n")
    assert_eq(@fs.mtime(destination), mtime)
    assert_eq(@fs.readdir(bin_dir, include_hidden=true).length(), 1)
  }
}

///|
async test "unmanaged different archive binary requires force to replace" {
  for format in ["zip", "tgz"] {
    let root = @fs.tmpdir(prefix="moon-binstall-adopt-different-\{format}")
    defer (@fs.rmdir(root, recursive=true) catch { _ => () })
    let bin_dir = root + "/bin"
    let destination = bin_dir + "/tool"
    @fs.mkdir(bin_dir)
    @fs.write_file(destination, "unmanaged-old\n")
    let mtime = @fs.mtime(destination)
    let transport = make_github_format_transport(
      root, "v1.2.3", "1.2.3", "verified-new\n", format,
    )
    let rejected = try {
      install_many_using(
        github_options(bin_dir, "v1.2.3", false),
        Fixture(transport),
      )
      false
    } catch {
      InstallError(stage=Destination, reason~, action~, ..) =>
        reason.contains("differs from the verified archive binary") &&
        action.contains("--force")
      _ => false
    }
    assert_true(rejected)
    assert_eq(@fs.read_file(destination).text(), "unmanaged-old\n")
    assert_eq(@fs.mtime(destination), mtime)
    assert_eq(@fs.readdir(bin_dir, include_hidden=true).length(), 1)
    install_many_using(
      github_options(bin_dir, "v1.2.3", true),
      Fixture(transport),
    )
    assert_eq(@fs.read_file(destination).text(), "verified-new\n")
    assert_true(read_receipt_file(receipt_path(bin_dir, "tool")) is Some(_))
  }
}

///|
async test "unmanaged matching archive binary still requires asset verification" {
  for format in ["zip", "tgz"] {
    let root = @fs.tmpdir(prefix="moon-binstall-adopt-corrupt-\{format}")
    defer (@fs.rmdir(root, recursive=true) catch { _ => () })
    let bin_dir = root + "/bin"
    @fs.mkdir(bin_dir)
    @fs.write_file(bin_dir + "/tool", "matching\n")
    let transport = make_github_format_transport(
      root, "v1.2.3", "1.2.3", "matching\n", format,
    )
    // Keep the published digest, but supply different downloaded bytes.
    @fs.write_file(transport.files[0].1, "corrupt archive\n")
    let rejected = try {
      install_many_using(
        github_options(bin_dir, "v1.2.3", false),
        Fixture(transport),
      )
      false
    } catch {
      InstallError(stage=Digest, ..) => true
      _ => false
    }
    assert_true(rejected)
    assert_eq(@fs.read_file(bin_dir + "/tool").text(), "matching\n")
    assert_eq(@fs.readdir(bin_dir, include_hidden=true).length(), 1)
  }
}

///|
async test "later unmanaged archive mismatch prevents earlier batch installation" {
  let root = @fs.tmpdir(prefix="moon-binstall-adopt-batch-mismatch")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let bin_dir = root + "/bin"
  @fs.mkdir(bin_dir)
  @fs.write_file(bin_dir + "/worker", "foreign-worker\n")
  let unrelated = bin_dir + "/.moon-binstall-stage-user-data"
  @fs.mkdir(unrelated)
  @fs.write_file(unrelated + "/keep", "user-owned\n")
  let rejected = try {
    install_many_using(
      registry_batch_options(bin_dir, false, false),
      Fixture(make_registry_fixture_transport(root, false)),
    )
    false
  } catch {
    InstallError(stage=Destination, reason~, ..) =>
      reason.contains("acme/toolkit/cmd/worker@1.2.3")
    _ => false
  }
  assert_true(rejected)
  assert_eq(@fs.read_file(bin_dir + "/worker").text(), "foreign-worker\n")
  assert_eq(@fs.read_file(unrelated + "/keep").text(), "user-owned\n")
  // No first-package binary, receipt, or owned staging remains.
  assert_eq(@fs.readdir(bin_dir, include_hidden=true).length(), 2)
}

///|
async test "later batch digest failure leaves an adopted archive binary unmanaged" {
  let root = @fs.tmpdir(prefix="moon-binstall-adopt-batch-digest")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let bin_dir = root + "/bin"
  @fs.mkdir(bin_dir)
  @fs.write_file(bin_dir + "/cli", "cli-fixture\n")
  let rejected = try {
    install_many_using(
      registry_batch_options(bin_dir, false, false),
      Fixture(make_registry_fixture_transport(root, true)),
    )
    false
  } catch {
    InstallError(stage=Digest, ..) => true
    _ => false
  }
  assert_true(rejected)
  assert_eq(@fs.read_file(bin_dir + "/cli").text(), "cli-fixture\n")
  assert_eq(@fs.readdir(bin_dir, include_hidden=true).length(), 1)
}

///|
/// Deterministic check of the post-download guard, without timing races.
async test "unmanaged archive adoption rejects changed missing or linked files" {
  for change in ["content", "missing", "symlink", "directory"] {
    let root = @fs.tmpdir(prefix="moon-binstall-adopt-changed-\{change}")
    defer (@fs.rmdir(root, recursive=true) catch { _ => () })
    let destination = root + "/tool"
    @fs.write_file(destination, "original\n")
    let digest = file_sha256(destination)
    let staged = StagedInstall::{
      destination,
      staging: root + "/unused-staging",
      staging_dir: root,
      binary_digest: digest,
    }
    @fs.remove(destination)
    match change {
      "content" => @fs.write_file(destination, "changed\n")
      "missing" => ()
      "symlink" => {
        @fs.write_file(root + "/target", "original\n")
        @fs.symlink(target=root + "/target", destination)
      }
      "directory" => @fs.mkdir(destination)
      _ => abort("unhandled change fixture")
    }
    let rejected = try {
      verify_existing_binary(staged, digest)
      false
    } catch {
      InstallError(stage=Destination, reason~, ..) =>
        reason.contains("changed while verifying")
      _ => false
    }
    assert_true(rejected)
  }
}

///|
/// A later package's extraction deterministically models an external change
/// after the first archive member was verified, before batch commit begins.
async test "later batch staging cannot bless a changed or linked adoption" {
  for
    (source, change) in [
      ("archive", "content"),
      ("archive", "symlink"),
      ("raw", "content"),
      ("raw", "symlink"),
    ] {
    let root = @fs.tmpdir(
      prefix="moon-binstall-adopt-later-\{source}-\{change}",
    )
    defer (@fs.rmdir(root, recursive=true) catch { _ => () })
    let bin_dir = root + "/bin"
    let destination = bin_dir + (if source == "raw" { "/tool" } else { "/cli" })
    let target = root + "/symlink-target"
    @fs.mkdir(bin_dir)
    @fs.write_file(destination, "cli-fixture\n")
    @fs.write_file(target, "cli-fixture\n")
    let unrelated = bin_dir + "/.moon-binstall-stage-user-data"
    @fs.mkdir(unrelated)
    @fs.write_file(unrelated + "/keep", "user-owned\n")
    let transport = make_registry_fixture_transport(root, false)
    let options = if source == "raw" {
      let raw = make_github_release_transport(
        root, "v1.2.3", "1.2.3", "cli-fixture\n",
      )
      for response in raw.responses {
        transport.responses.push(response)
      }
      for file in raw.files {
        transport.files.push(file)
      }
      parse_batch_options([
        "acme/tool@v1.2.3", "acme/toolkit/cmd/worker@1.2.3", "--bin-dir", bin_dir,
        "--target", "linux-x86_64",
      ])
    } else {
      registry_batch_options(bin_dir, false, false)
    }
    let real_zipinfo = path_resolved_candidates("zipinfo")[0]
    let wrapper_dir = root + "/wrapper"
    @fs.mkdir(wrapper_dir)
    let script =
      #|#!/bin/sh
      #|case "$2" in
      #|  */asset-1)
      #|    case "$MOON_BINSTALL_TEST_CHANGE" in
      #|      content) printf 'unverified-change\n' > "$MOON_BINSTALL_TEST_DESTINATION" ;;
      #|      symlink)
      #|        rm -f "$MOON_BINSTALL_TEST_DESTINATION"
      #|        ln -s "$MOON_BINSTALL_TEST_TARGET" "$MOON_BINSTALL_TEST_DESTINATION"
      #|        ;;
      #|    esac
      #|    ;;
      #|esac
      #|exec "$MOON_BINSTALL_TEST_ZIPINFO" "$@"
      #|
    @fs.write_file(wrapper_dir + "/zipinfo", script)
    @fs.chmod(wrapper_dir + "/zipinfo", 0o755)
    let saved : Array[(String, String?)] = []
    for
      name in [
        "PATH", "MOON_BINSTALL_TEST_CHANGE", "MOON_BINSTALL_TEST_DESTINATION", "MOON_BINSTALL_TEST_TARGET",
        "MOON_BINSTALL_TEST_ZIPINFO",
      ] {
      saved.push((name, @env.get_env_var(name)))
    }
    defer (for (name, value) in saved {
      match value {
        Some(value) => @env.set_env_var(name, value)
        None => @env.unset_env_var(name)
      }
    })
    @env.set_env_var("PATH", wrapper_dir + ":" + saved[0].1.unwrap())
    @env.set_env_var("MOON_BINSTALL_TEST_CHANGE", change)
    @env.set_env_var("MOON_BINSTALL_TEST_DESTINATION", destination)
    @env.set_env_var("MOON_BINSTALL_TEST_TARGET", target)
    @env.set_env_var("MOON_BINSTALL_TEST_ZIPINFO", real_zipinfo)
    let rejected = try {
      install_many_using(options, Fixture(transport))
      false
    } catch {
      InstallError(stage=Destination, reason~, ..) =>
        reason.contains("changed while verifying")
      _ => false
    }
    assert_true(rejected)
    if change == "content" {
      assert_eq(@fs.read_file(destination).text(), "unverified-change\n")
    } else {
      assert_true(path_kind_no_follow(destination) is Some(SymLink))
      assert_eq(@fs.read_file(target).text(), "cli-fixture\n")
    }
    assert_true(!@fs.exists(bin_dir + "/worker"))
    assert_true(!@fs.exists(bin_dir + "/.moon-binstall-receipts"))
    assert_eq(@fs.read_file(unrelated + "/keep").text(), "user-owned\n")
    assert_eq(@fs.readdir(bin_dir, include_hidden=true).length(), 2)
  }
}
