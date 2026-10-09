///|
async fn fixture_digest(path : String) -> String {
  let bytes = @fs.read_file(path).binary()
  "sha256:" + @crypto.bytes_to_hex_string(@crypto.sha256(bytes))
}

///|
async fn create_fixture_zip(
  archive : String,
  member_path : String,
  content : String,
) -> Unit {
  let script = "import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],'w'); z.writestr(sys.argv[2],sys.argv[3].encode()); z.close()"
  let result = @shell.Cmd("python3", [
    "-c", script, archive, member_path, content,
  ]).output()
  assert_eq(result.exit_code(), 0)
}

///|
async fn create_fixture_tar(
  root : String,
  archive : String,
  content : String,
  member_path : String,
) -> Unit {
  let source = root + "/source"
  let parts = member_path.split("/").collect()
  let mut parent = source
  for i = 0; i < parts.length() - 1; i = i + 1 {
    parent = parent + "/" + parts[i].to_owned()
  }
  @fs.mkdir(parent, recursive=true)
  @fs.write_file(source + "/" + member_path, content)
  let result = @shell.Cmd("tar", ["-czf", archive, "-C", source, member_path]).output()
  assert_eq(result.exit_code(), 0)
}

///|
async fn create_module_manifest_zip(
  archive : String,
  manifest : String,
) -> Unit {
  let script = "import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],'w'); z.writestr('moon-binstall.json',sys.argv[2]); z.close()"
  let result = @shell.Cmd("python3", ["-c", script, archive, manifest]).output()
  assert_eq(result.exit_code(), 0)
}

///|
async fn make_registry_fixture_transport(
  root : String,
  corrupt_worker_digest : Bool,
) -> FixtureTransport {
  let manifest = "{\"repository\":\"https://github.com/acme/tools\",\"packages\":[{\"package\":\"cmd/cli\",\"binary\":\"cli\",\"pkg-url\":\"{repo}/releases/download/v{version}/{bin}-{target}-{version}{archive-suffix}\",\"pkg-fmt\":\"tgz\",\"bin-path\":\"{package}/{bin}\"},{\"package\":\"cmd/worker\",\"binary\":\"worker\",\"pkg-url\":\"{repo}/releases/download/v{version}/{bin}-{target}-{version}{archive-suffix}\",\"pkg-fmt\":\"zip\",\"bin-path\":\"{package}/{bin}\"}]}"
  let source_zip = root + "/module-source.zip"
  create_module_manifest_zip(source_zip, manifest)
  let source_digest = fixture_digest(source_zip)

  let cli_archive = root + "/cli.tgz"
  create_fixture_tar(
    root + "/cli-src",
    cli_archive,
    "cli-fixture\n",
    "cmd/cli/cli",
  )
  let worker_archive = root + "/worker.zip"
  create_fixture_zip(worker_archive, "cmd/worker/worker", "worker-fixture\n")
  let cli_digest = fixture_digest(cli_archive)
  let worker_digest = if corrupt_worker_digest {
    "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  } else {
    fixture_digest(worker_archive)
  }
  let metadata_url = "https://mooncakes.io/api/v0/manifest/acme/toolkit@1.2.3"
  let latest_metadata_url = "https://mooncakes.io/api/v0/manifest/acme/toolkit"
  let source_url = "https://download.mooncakes.io/user/acme/toolkit/1.2.3.zip"
  let metadata = "{\"module\":\"acme/toolkit\",\"version\":\"1.2.3\",\"yanked\":false,\"metadata\":{\"repository\":\"https://github.com/acme/tools\",\"checksum\":\"\{source_digest[7:].to_owned()}\"}}"
  let cli_name = "cli-linux-x86_64-1.2.3.tgz"
  let worker_name = "worker-linux-x86_64-1.2.3.zip"
  let cli_url = "https://github.com/acme/tools/releases/download/v1.2.3/\{cli_name}"
  let worker_url = "https://github.com/acme/tools/releases/download/v1.2.3/\{worker_name}"
  let release_url = "https://api.github.com/repos/acme/tools/releases/tags/v1.2.3"
  let release = "{\"tag_name\":\"v1.2.3\",\"assets\":[{\"name\":\"\{cli_name}\",\"browser_download_url\":\"\{cli_url}\",\"digest\":\"\{cli_digest}\"},{\"name\":\"\{worker_name}\",\"browser_download_url\":\"\{worker_url}\",\"digest\":\"\{worker_digest}\"}]}"
  {
    responses: [
      (metadata_url, metadata),
      (latest_metadata_url, metadata),
      (release_url, release),
    ],
    files: [
      (source_url, source_zip),
      (cli_url, cli_archive),
      (worker_url, worker_archive),
    ],
  }
}

///|
fn registry_batch_options(
  bin_dir : String,
  force : Bool,
  dry_run : Bool,
) -> BatchOptions raise {
  let args : Array[String] = [
    "acme/toolkit/cmd/cli@1.2.3", "acme/toolkit/cmd/worker@1.2.3", "--bin-dir", bin_dir,
    "--target", "linux-x86_64",
  ]
  if force {
    args.push("--force")
  }
  if dry_run {
    args.push("--dry-run")
  }
  parse_batch_options(args)
}

///|
async fn fixture_install(
  archive : String,
  output_dir : String,
  format : String,
  digest : String,
) -> Unit {
  let asset_name = "fixture-linux-x86_64-1.2.3" + archive_suffix(format)
  let url = "https://github.com/example/tools/releases/download/v1.2.3/\{asset_name}"
  let payload = "{\"tag_name\":\"v1.2.3\",\"assets\":[{\"name\":\"\{asset_name}\",\"browser_download_url\":\"\{url}\",\"digest\":\"\{digest}\"}]}"
  let config : ArtifactConfig = {
    package_path: "cmd/fixture",
    binary: "fixture",
    pkg_url: Some(
      "https://github.com/example/tools/releases/download/v1.2.3/{bin}-{target}-{version}{archive-suffix}",
    ),
    pkg_fmt: Some(format),
    bin_path: if format == "bin" {
      None
    } else {
      Some("bin/{bin}")
    },
  }
  let options : BatchOptions = {
    coordinates: [],
    directory: None,
    dry_run: false,
    force: false,
    target: Some("linux-x86_64"),
    version: None,
    pkg_url: None,
    pkg_fmt: None,
    bin_path: None,
    module_path: None,
    manifest_path: None,
  }
  let resolved = resolve_asset_for_release(
    payload,
    "example",
    "tools",
    "fixture",
    "tools",
    "cmd/fixture",
    "1.2.3",
    "linux-x86_64",
    Some(config),
    options,
  )
  assert_eq(resolved.asset.name, asset_name)
  assert_eq(resolved.binary, "fixture")
  if format == "bin" {
    assert_eq(resolved.bin_path, None)
  } else {
    assert_eq(resolved.bin_path, Some("bin/fixture"))
  }
  install_from_asset_file(
    archive,
    resolved.asset.digest,
    resolved.format,
    resolved.bin_path,
    resolved.binary,
    output_dir,
    false,
  )
}

///|
async test "raw, tgz and ZIP release fixtures resolve and install executable bytes" {
  let root = @fs.tmpdir(prefix="moon-binstall-archives")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let content = "#!/bin/sh\necho fixture\n"
  let raw = root + "/fixture.bin"
  @fs.write_file(raw, content)
  let raw_digest = fixture_digest(raw)
  let raw_bin_dir = root + "/raw-bin"
  fixture_install(raw, raw_bin_dir, "bin", raw_digest)
  assert_eq(@fs.read_file(raw_bin_dir + "/fixture").text(), content)
  assert_true(@fs.can_execute(raw_bin_dir + "/fixture"))

  let tar = root + "/fixture.tgz"
  create_fixture_tar(root, tar, content, "bin/fixture")
  let tar_bin_dir = root + "/tar-bin"
  fixture_install(tar, tar_bin_dir, "tgz", fixture_digest(tar))
  assert_eq(@fs.read_file(tar_bin_dir + "/fixture").text(), content)
  assert_true(@fs.can_execute(tar_bin_dir + "/fixture"))

  let zip = root + "/fixture.zip"
  create_fixture_zip(zip, "bin/fixture", content)
  let zip_bin_dir = root + "/zip-bin"
  fixture_install(zip, zip_bin_dir, "zip", fixture_digest(zip))
  assert_eq(@fs.read_file(zip_bin_dir + "/fixture").text(), content)
  assert_true(@fs.can_execute(zip_bin_dir + "/fixture"))
  assert_eq(@fs.readdir(zip_bin_dir, include_hidden=true).length(), 1)
}

///|
async test "ZIP member with unspecified Unix type bits remains a regular file" {
  let root = @fs.tmpdir(prefix="moon-binstall-zip-mode")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let archive = root + "/unknown-mode.zip"
  create_fixture_zip(archive, "bin/fixture", "unknown mode")
  assert_eq(
    @utf8.decode(read_artifact_binary(archive, "zip", Some("bin/fixture"))),
    "unknown mode",
  )
}

///|
test "archive duplicate path validation sorts before checking neighbors" {
  let duplicate = try {
    validate_unique_archive_paths(["z", "a", "m", "a"])
    false
  } catch {
    _ => true
  }
  assert_true(duplicate)
  validate_unique_archive_paths(["z", "a", "m"])
}

///|
async test "archive traversal links options and duplicate ZIP members fail closed" {
  let root = @fs.tmpdir(prefix="moon-binstall-unsafe-archive")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let script_prefix = "import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],'w'); "

  let traversal = root + "/traversal.zip"
  let traversal_script = script_prefix +
    "z.writestr('../escape',b'bad'); z.writestr('bin/fixture',b'safe'); z.close()"
  let traversal_result = @shell.Cmd("python3", [
    "-c", traversal_script, traversal,
  ]).output()
  assert_eq(traversal_result.exit_code(), 0)
  let traversal_rejected = try {
    ignore(read_artifact_binary(traversal, "zip", Some("bin/fixture")))
    false
  } catch {
    _ => true
  }
  assert_true(traversal_rejected)
  let traversal_install_dir = root + "/traversal-install"
  @fs.mkdir(traversal_install_dir)
  @fs.write_file(traversal_install_dir + "/fixture", "preserve-me")
  let traversal_install_rejected = try {
    install_from_asset_file(
      traversal,
      fixture_digest(traversal),
      "zip",
      Some("bin/fixture"),
      "fixture",
      traversal_install_dir,
      true,
    )
    false
  } catch {
    _ => true
  }
  assert_true(traversal_install_rejected)
  assert_eq(
    @fs.read_file(traversal_install_dir + "/fixture").text(),
    "preserve-me",
  )

  let link = root + "/link.zip"
  let link_script = "import sys,zipfile,stat; z=zipfile.ZipFile(sys.argv[1],'w'); i=zipfile.ZipInfo('bin/fixture'); i.create_system=3; i.external_attr=(stat.S_IFLNK|0o777)<<16; z.writestr(i,'/etc/passwd'); z.close()"
  let link_result = @shell.Cmd("python3", ["-c", link_script, link]).output()
  assert_eq(link_result.exit_code(), 0)
  let link_rejected = try {
    ignore(read_artifact_binary(link, "zip", Some("bin/fixture")))
    false
  } catch {
    _ => true
  }
  assert_true(link_rejected)

  let duplicate = root + "/duplicate.zip"
  let duplicate_script = "import sys,warnings,zipfile; warnings.filterwarnings('ignore'); z=zipfile.ZipFile(sys.argv[1],'w'); z.writestr('bin/fixture',b'one'); z.writestr('bin/fixture',b'two'); z.close()"
  let duplicate_result = @shell.Cmd("python3", [
    "-c", duplicate_script, duplicate,
  ]).output()
  assert_eq(duplicate_result.exit_code(), 0)
  let duplicate_rejected = try {
    ignore(read_artifact_binary(duplicate, "zip", Some("bin/fixture")))
    false
  } catch {
    _ => true
  }
  assert_true(duplicate_rejected)
  assert_true(
    try {
      validate_member_path("--help")
      false
    } catch {
      _ => true
    },
  )
}

///|
async test "tar traversal and symlink members are rejected" {
  let root = @fs.tmpdir(prefix="moon-binstall-unsafe-tar")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let traversal = root + "/traversal.tgz"
  let traversal_script = "import io,sys,tarfile; t=tarfile.open(sys.argv[1],'w:gz'); x=tarfile.TarInfo('../escape'); d=b'bad'; x.size=len(d); t.addfile(x,io.BytesIO(d)); y=tarfile.TarInfo('bin/fixture'); e=b'safe'; y.size=len(e); t.addfile(y,io.BytesIO(e)); t.close()"
  let traversal_result = @shell.Cmd("python3", [
    "-c", traversal_script, traversal,
  ]).output()
  assert_eq(traversal_result.exit_code(), 0)
  assert_true(
    try {
      ignore(read_artifact_binary(traversal, "tgz", Some("bin/fixture")))
      false
    } catch {
      _ => true
    },
  )

  let link = root + "/link.tgz"
  let link_script = "import sys,tarfile; t=tarfile.open(sys.argv[1],'w:gz'); x=tarfile.TarInfo('bin/fixture'); x.type=tarfile.SYMTYPE; x.linkname='/etc/passwd'; t.addfile(x); t.close()"
  let link_result = @shell.Cmd("python3", ["-c", link_script, link]).output()
  assert_eq(link_result.exit_code(), 0)
  assert_true(
    try {
      ignore(read_artifact_binary(link, "tgz", Some("bin/fixture")))
      false
    } catch {
      _ => true
    },
  )
}

///|
async test "decompression stdout is bounded before it is captured" {
  let root = @fs.tmpdir(prefix="moon-binstall-output-cap")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let tar = root + "/large.tgz"
  let script = "import io,sys,tarfile; t=tarfile.open(sys.argv[1],'w:gz'); x=tarfile.TarInfo('bin/large'); d=b'A'*100000; x.size=len(d); t.addfile(x,io.BytesIO(d)); t.close()"
  let result = @shell.Cmd("python3", ["-c", script, tar]).output()
  assert_eq(result.exit_code(), 0)
  let rejected = try {
    ignore(read_artifact_binary_with_limit(tar, "tgz", Some("bin/large"), 64))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
async test "installer rejects dangling destination symlinks and skips staging symlinks" {
  let root = @fs.tmpdir(prefix="moon-binstall-symlink")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let raw = root + "/fixture.bin"
  @fs.write_file(raw, "verified")
  let digest = fixture_digest(raw)
  let bin_dir = root + "/bin"
  @fs.mkdir(bin_dir)
  let destination = bin_dir + "/blocked"
  @fs.symlink(target="missing-target", destination, force_symlink=true)
  let dest_rejected = try {
    install_from_asset_file(raw, digest, "bin", None, "blocked", bin_dir, true)
    false
  } catch {
    _ => true
  }
  assert_true(dest_rejected)
  assert_true(@fs.kind(destination, follow_symlink=false) is SymLink)

  // Exercise the exclusive allocation routine with a dangling first candidate.
  let colliding_link = bin_dir + "/.moon-binstall-stage-fixture-0-0"
  @fs.symlink(target="missing-stage-target", colliding_link, force_symlink=true)
  let allocated = create_staging_directory_at(bin_dir, 0, "fixture")
  assert_eq(allocated, bin_dir + "/.moon-binstall-stage-fixture-0-1")
  @fs.rmdir(allocated)
  install_from_asset_file(raw, digest, "bin", None, "safe", bin_dir, false)
  assert_eq(@fs.read_file(bin_dir + "/safe").text(), "verified")
  assert_true(@fs.kind(colliding_link, follow_symlink=false) is SymLink)

  let bad_digest_rejected = try {
    install_from_asset_file(
      raw,
      "sha256:xyz",
      "bin",
      None,
      "bad",
      bin_dir,
      false,
    )
    false
  } catch {
    _ => true
  }
  assert_true(bad_digest_rejected)
  assert_true(!@fs.exists(bin_dir + "/bad"))
}

///|
async test "Mooncakes exact metadata resolves source manifest and installs a two-package batch" {
  let root = @fs.tmpdir(prefix="moon-binstall-registry-e2e")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let output = root + "/installed"
  let transport = make_registry_fixture_transport(root, false)
  install_many_using(
    registry_batch_options(output, false, false),
    Fixture(transport),
  )
  assert_eq(@fs.read_file(output + "/cli").text(), "cli-fixture\n")
  assert_eq(@fs.read_file(output + "/worker").text(), "worker-fixture\n")
  assert_true(@fs.can_execute(output + "/cli"))
  assert_true(@fs.can_execute(output + "/worker"))
  assert_eq(@fs.readdir(output, include_hidden=true).length(), 2)
}

///|
async test "Mooncakes latest lookup pins the returned version before GitHub resolution" {
  let root = @fs.tmpdir(prefix="moon-binstall-registry-latest")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let options = parse_batch_options([
    "acme/toolkit/cmd/cli",
    "--bin-dir",
    root + "/installed",
    "--target",
    "linux-x86_64",
  ])
  let transport = make_registry_fixture_transport(root, false)
  install_many_using(options, Fixture(transport))
  assert_eq(@fs.read_file(root + "/installed/cli").text(), "cli-fixture\n")
}

///|
async test "repository manifest maps cmd main to the published installer asset" {
  let payload = @fs.read_file("moon-binstall.json").text()
  let repository = manifest_repository(payload, "f4ah6o/moon-binstall")
  let config = match parse_artifact_config(payload, "cmd/main", "main") {
    Some(value) => value
    None => fail("repository manifest is missing cmd/main")
  }
  assert_eq(repository, "https://github.com/f4ah6o/moon-binstall")
  assert_eq(config.binary, "moon-binstall")
  assert_eq(config.pkg_fmt, Some("bin"))
  assert_eq(
    config.pkg_url,
    Some("{repo}/releases/download/v{version}/{bin}-{target}"),
  )
}

///|
async test "explicit v-prefixed GitHub tag uses normalized version in archive template" {
  let root = @fs.tmpdir(prefix="moon-binstall-explicit-tag")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let asset_name = "tool-1.2.3-linux-x86_64.tgz"
  let asset_url = "https://github.com/acme/tool/releases/download/v1.2.3/\{asset_name}"
  let payload = "{\"tag_name\":\"v1.2.3\",\"assets\":[{\"name\":\"\{asset_name}\",\"browser_download_url\":\"\{asset_url}\",\"digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}]}"
  let api = "https://api.github.com/repos/acme/tool/releases/tags/v1.2.3"
  let options = parse_batch_options([
    "acme/tool@v1.2.3", "--pkg-url", "https://github.com/acme/tool/releases/download/v{version}/{bin}-{version}-{target}{archive-suffix}",
    "--pkg-fmt", "tgz", "--target", "linux-x86_64",
  ])
  let resolved = resolve_package(
    options.coordinates[0],
    options,
    "linux-x86_64",
    root,
    0,
    Fixture({ responses: [(api, payload)], files: [], }),
  )
  assert_eq(resolved.asset.tag, "v1.2.3")
  assert_eq(resolved.asset.name, asset_name)
  assert_eq(resolved.format, "tgz")
}

///|
async test "second package digest failure preserves existing files and removes owned staging" {
  let root = @fs.tmpdir(prefix="moon-binstall-batch-failure")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let output = root + "/installed"
  @fs.mkdir(output)
  @fs.write_file(output + "/cli", "previous-cli\n")
  let transport = make_registry_fixture_transport(root, true)
  let rejected = try {
    install_many_using(
      registry_batch_options(output, true, false),
      Fixture(transport),
    )
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  assert_eq(@fs.read_file(output + "/cli").text(), "previous-cli\n")
  assert_true(!@fs.exists(output + "/worker"))
  assert_eq(@fs.readdir(output, include_hidden=true).length(), 1)
}

///|
async test "dry run resolves a two-package batch without creating the destination" {
  let root = @fs.tmpdir(prefix="moon-binstall-batch-dry-run")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let output = root + "/not-created"
  let transport = make_registry_fixture_transport(root, false)
  install_many_using(
    registry_batch_options(output, false, true),
    Fixture(transport),
  )
  assert_true(!@fs.exists(output))
}

///|
async test "local manifest skips Mooncakes lookup and force replaces a regular binary" {
  let root = @fs.tmpdir(prefix="moon-binstall-local-manifest")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let manifest = "{\"repository\":\"https://github.com/acme/tools\",\"version\":\"1.2.3\",\"packages\":[{\"package\":\"cmd/cli\",\"binary\":\"cli\",\"pkg-url\":\"{repo}/releases/download/v{version}/{bin}-{target}-{version}{archive-suffix}\",\"pkg-fmt\":\"tgz\",\"bin-path\":\"{package}/{bin}\"}]}"
  let manifest_path = root + "/moon-binstall.json"
  @fs.write_file(manifest_path, manifest)
  let full_transport = make_registry_fixture_transport(root, false)
  // The local manifest path has no registry/source routes. Success proves
  // the installer bypasses Mooncakes lookup and only uses the GitHub fixture.
  let transport = FixtureTransport::{
    responses: [full_transport.responses[2]],
    files: [full_transport.files[1]],
  }
  let options = parse_batch_options([
    "acme/toolkit/cmd/cli@1.2.3",
    "--manifest-path",
    manifest_path,
    "--bin-dir",
    root + "/installed",
    "--target",
    "linux-x86_64",
    "--force",
  ])
  @fs.mkdir(root + "/installed")
  @fs.write_file(root + "/installed/cli", "old-cli\n")
  install_many_using(options, Fixture(transport))
  assert_eq(@fs.read_file(root + "/installed/cli").text(), "cli-fixture\n")
}
