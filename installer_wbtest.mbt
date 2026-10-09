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
  create_fixture_tar_format(root, archive, content, member_path, "tgz")
}

///|
async fn create_fixture_tar_format(
  root : String,
  archive : String,
  content : String,
  member_path : String,
  format : String,
) -> Unit {
  let source = root + "/source"
  let parts = member_path.split("/").collect()
  let mut parent = source
  for i = 0; i < parts.length() - 1; i = i + 1 {
    parent = parent + "/" + parts[i].to_owned()
  }
  @fs.mkdir(parent, recursive=true)
  @fs.write_file(source + "/" + member_path, content)
  let plain = root + "/source.tar"
  let result = @shell.Cmd("tar", ["-cf", plain, "-C", source, member_path]).output()
  assert_eq(result.exit_code(), 0)
  compress_fixture_tar(plain, archive, format)
}

///|
async fn compress_fixture_tar(
  plain : String,
  archive : String,
  format : String,
) -> Unit {
  let compressor = match format {
    "tar" => None
    "tgz" | "tar.gz" => Some("gzip")
    "tbz2" | "tar.bz2" => Some("bzip2")
    "txz" | "tar.xz" => Some("xz")
    "tzstd" | "tar.zst" | "tar.zstd" => Some("zstd")
    _ => fail("unknown tar fixture format: {format}")
  }
  match compressor {
    Some(program) => {
      let output = @shell.Cmd(program, ["-c", plain]).output(
        max_output_bytes=1048576,
      )
      assert_eq(output.exit_code(), 0)
      @fs.write_file(archive, output.stdout_bytes(), create_mode=CreateNew)
    }
    None =>
      @fs.write_file(
        archive,
        @fs.read_file(plain).binary(),
        create_mode=CreateNew,
      )
  }
}

///|
async fn create_unsafe_fixture_tar(
  root : String,
  archive : String,
  format : String,
) -> Unit {
  @fs.mkdir(root, recursive=true)
  let plain = root + "/unsafe-" + format + ".tar"
  let script = "import io,sys,tarfile; t=tarfile.open(sys.argv[1],'w'); x=tarfile.TarInfo('../escape'); d=b'bad'; x.size=len(d); t.addfile(x,io.BytesIO(d)); y=tarfile.TarInfo('bin/fixture'); e=b'safe'; y.size=len(e); t.addfile(y,io.BytesIO(e)); t.close()"
  let result = @shell.Cmd("python3", ["-c", script, plain]).output()
  assert_eq(result.exit_code(), 0)
  compress_fixture_tar(plain, archive, format)
}

///|
/// Build a valid gzip FEXTRA stream whose first 512 bytes pass the tar
/// checksum check, reproducing a compression auto-detection ambiguity.
async fn create_gzip_with_tar_checksum_fixture(archive : String) -> Unit {
  let script = [
    "import io, struct, sys, tarfile, zlib",
    "plain = io.BytesIO()",
    "with tarfile.open(fileobj=plain, mode='w') as archive:",
    "    member = tarfile.TarInfo('bin/fixture')",
    "    data = b'forged gzip fixture' + bytes([10])",
    "    member.size = len(data)",
    "    archive.addfile(member, io.BytesIO(data))",
    "tar_data = plain.getvalue()",
    "header = bytearray(bytes([31, 139, 8, 4]) + bytes(4) + bytes([0, 255]) + struct.pack('<H', 500) + bytes(500))",
    "header[148:156] = bytes([32]) * 8",
    "checksum = sum(header)",
    "header[148:156] = ('%06o' % checksum).encode() + bytes([0, 32])",
    "assert int(header[148:154], 8) == checksum",
    "compressor = zlib.compressobj(wbits=-15)",
    "gzip_data = bytes(header) + compressor.compress(tar_data) + compressor.flush() + struct.pack('<II', zlib.crc32(tar_data), len(tar_data))",
    "open(sys.argv[1], 'wb').write(gzip_data)",
  ].join("\n")
  let result = @shell.Cmd("python3", ["-c", script, archive]).output()
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
async fn make_case_collision_transport(root : String) -> FixtureTransport {
  let source_zip = root + "/case-module-source.zip"
  let source_manifest = "{\"repository\":\"https://github.com/acme/tools\",\"packages\":[{\"package\":\"cmd/first\",\"binary\":\"tool\",\"pkg-url\":\"{repo}/releases/download/v{version}/{bin}-{target}\",\"pkg-fmt\":\"bin\"},{\"package\":\"cmd/second\",\"binary\":\"Tool\",\"pkg-url\":\"{repo}/releases/download/v{version}/{bin}-{target}\",\"pkg-fmt\":\"bin\"}]}"
  create_module_manifest_zip(source_zip, source_manifest)
  let source_digest = fixture_digest(source_zip)

  let lower_binary = root + "/tool.bin"
  let upper_binary = root + "/Tool.bin"
  @fs.write_file(lower_binary, "lower-case binary\n")
  @fs.write_file(upper_binary, "upper-case binary\n")
  let lower_digest = fixture_digest(lower_binary)
  let upper_digest = fixture_digest(upper_binary)
  let lower_name = "tool-linux-x86_64"
  let upper_name = "Tool-linux-x86_64"
  let lower_url = "https://github.com/acme/tools/releases/download/v1.2.3/\{lower_name}"
  let upper_url = "https://github.com/acme/tools/releases/download/v1.2.3/\{upper_name}"
  let registry_url = "https://mooncakes.io/api/v0/manifest/acme/toolkit@1.2.3"
  let metadata = "{\"module\":\"acme/toolkit\",\"version\":\"1.2.3\",\"yanked\":false,\"metadata\":{\"repository\":\"https://github.com/acme/tools\",\"checksum\":\"\{source_digest[7:].to_owned()}\"}}"
  let release_url = "https://api.github.com/repos/acme/tools/releases/tags/v1.2.3"
  let release = "{\"tag_name\":\"v1.2.3\",\"assets\":[{\"name\":\"\{lower_name}\",\"browser_download_url\":\"\{lower_url}\",\"digest\":\"\{lower_digest}\"},{\"name\":\"\{upper_name}\",\"browser_download_url\":\"\{upper_url}\",\"digest\":\"\{upper_digest}\"}]}"
  {
    responses: [(registry_url, metadata), (release_url, release)],
    files: [
      ("https://download.mooncakes.io/user/acme/toolkit/1.2.3.zip", source_zip),
      (lower_url, lower_binary),
      (upper_url, upper_binary),
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
async test "tar codec formats extract only the selected member and enforce bounds" {
  let root = @fs.tmpdir(prefix="moon-binstall-tar-codecs")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let content = "codec fixture payload"
  let formats = [
    "tar", "tgz", "tar.gz", "tbz2", "tar.bz2", "txz", "tar.xz",
    "tzstd", "tar.zst",
  ]
  for i = 0; i < formats.length(); i = i + 1 {
    let format = formats[i]
    let suffix = archive_suffix(format)
    let archive = root + "/safe-" + i.to_string() + suffix
    create_fixture_tar_format(
      root + "/safe-src-" + i.to_string(), archive, content,
      "bin/fixture", format,
    )
    assert_eq(
      @utf8.decode(read_artifact_binary(archive, format, Some("bin/fixture"))),
      content,
    )
    if format != "tar" {
      assert_true(
        try {
          ignore(read_artifact_binary(archive, "tar", Some("bin/fixture")))
          false
        } catch {
          _ => true
        },
      )
    }
    assert_true(
      try {
        ignore(
          read_artifact_binary_with_limit(
            archive, format, Some("bin/fixture"), 3,
          ),
        )
        false
      } catch {
        _ => true
      },
    )

    let unsafe_archive = root + "/unsafe-" + i.to_string() + suffix
    create_unsafe_fixture_tar(
      root + "/unsafe-src-" + i.to_string(), unsafe_archive, format,
    )
    assert_true(
      try {
        ignore(
          read_artifact_binary(
            unsafe_archive, format, Some("bin/fixture"),
          ),
        )
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
async test "tar reader rejects bytes whose compression conflicts with declared format" {
  let root = @fs.tmpdir(prefix="moon-binstall-format-mismatch")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let gzip_archive = root + "/fixture.tgz"
  create_fixture_tar_format(
    root + "/gzip-src", gzip_archive, "fixture", "bin/fixture", "tgz",
  )
  assert_true(
    try {
      ignore(read_artifact_binary(gzip_archive, "tbz2", Some("bin/fixture")))
      false
    } catch {
      _ => true
    },
  )
  let plain_archive = root + "/fixture.tar"
  create_fixture_tar_format(
    root + "/plain-src", plain_archive, "fixture", "bin/fixture", "tar",
  )
  assert_true(
    try {
      ignore(read_artifact_binary(plain_archive, "tar.gz", Some("bin/fixture")))
      false
    } catch {
      _ => true
    },
  )
  let zip_archive = root + "/fixture.zip"
  create_fixture_zip(zip_archive, "bin/fixture", "fixture")
  assert_true(
    try {
      ignore(read_artifact_binary(zip_archive, "tar", Some("bin/fixture")))
      false
    } catch {
      _ => true
    },
  )

  let forged_gzip_archive = root + "/gzip-with-tar-checksum.tar"
  create_gzip_with_tar_checksum_fixture(forged_gzip_archive)
  assert_true(
    try {
      ignore(
        read_artifact_binary(
          forged_gzip_archive, "tar", Some("bin/fixture"),
        ),
      )
      false
    } catch {
      _ => true
    },
  )
}

///|
async test "plain tar accepts member names that resemble ASCII container magic" {
  let root = @fs.tmpdir(prefix="moon-binstall-tar-ascii-magic-names")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let content = "valid plain tar member"
  for name in [
    "BZh-tool", "LZIP-tool", "070701-tool", "070702-tool", "070707-tool",
    "MSCF-tool",
  ] {
    let archive = root + "/" + name + ".tar"
    create_fixture_tar_format(
      root + "/source-" + name, archive, content, name, "tar",
    )
    assert_eq(
      @utf8.decode(read_artifact_binary(archive, "tar", Some(name))),
      content,
    )
  }
}

///|
test "ordered targets prefer earlier assets and apply the matched target to templates" {
  let options = parse_batch_options([
    "acme/tool@v1.0.0", "--targets", "linux-x86_64,darwin-aarch64", "--pkg-url",
    "https://github.com/acme/tool/releases/download/v1.0.0/{bin}-{target}{archive-suffix}",
    "--pkg-fmt", "tgz", "--bin-path", "bin/{target}/{bin}",
  ])
  let first_name = "tool-linux-x86_64.tgz"
  let first_url = "https://github.com/acme/tool/releases/download/v1.0.0/" + first_name
  let second_name = "tool-darwin-aarch64.tgz"
  let second_url = "https://github.com/acme/tool/releases/download/v1.0.0/" + second_name
  let digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let first_asset = "{\"name\":\"" + first_name + "\",\"browser_download_url\":\"" + first_url + "\",\"digest\":\"" + digest + "\"}"
  let second_asset = "{\"name\":\"" + second_name + "\",\"browser_download_url\":\"" + second_url + "\",\"digest\":\"" + digest + "\"}"
  let only_second = "{\"tag_name\":\"v1.0.0\",\"assets\":[" + second_asset + "]}"
  let resolved_second = resolve_asset_for_release(
    only_second, "acme", "tool", "tool", "tool", "tool", "1.0.0",
    "linux-x86_64", None, options,
  )
  assert_eq(resolved_second.asset.name, second_name)
  assert_eq(resolved_second.bin_path, Some("bin/darwin-aarch64/tool"))

  let both = "{\"tag_name\":\"v1.0.0\",\"assets\":[" + first_asset + "," + second_asset + "]}"
  let resolved_first = resolve_asset_for_release(
    both, "acme", "tool", "tool", "tool", "tool", "1.0.0",
    "linux-x86_64", None, options,
  )
  assert_eq(resolved_first.asset.name, first_name)

  let unrelated_unsafe = "{\"name\":\"other-linux-x86_64.tgz\",\"browser_download_url\":\"https://evil.example/asset\",\"digest\":\"sha512:bad\"}"
  let with_unselected_unsafe = "{\"tag_name\":\"v1.0.0\",\"assets\":[" + unrelated_unsafe + "," + first_asset + "]}"
  let resolved_with_unselected_unsafe = resolve_asset_for_release(
    with_unselected_unsafe, "acme", "tool", "tool", "tool", "tool", "1.0.0",
    "linux-x86_64", None, options,
  )
  assert_eq(resolved_with_unselected_unsafe.asset.name, first_name)

  let empty = "{\"tag_name\":\"v1.0.0\",\"assets\":[]}"
  assert_true(
    try {
      ignore(
        resolve_asset_for_release(
          empty, "acme", "tool", "tool", "tool", "tool", "1.0.0",
          "linux-x86_64", None, options,
        ),
      )
      false
    } catch {
      _ => true
    },
  )
}

///|
test "malformed preferred target assets fail closed instead of falling back" {
  let options = parse_batch_options([
    "acme/tool@v1.0.0", "--targets", "linux-x86_64,darwin-aarch64", "--pkg-url",
    "https://github.com/acme/tool/releases/download/v1.0.0/{bin}-{target}{archive-suffix}",
    "--pkg-fmt", "tgz",
  ])
  let first_name = "tool-linux-x86_64.tgz"
  let first_url = "https://github.com/acme/tool/releases/download/v1.0.0/" + first_name
  let second_name = "tool-darwin-aarch64.tgz"
  let second_url = "https://github.com/acme/tool/releases/download/v1.0.0/" + second_name
  let digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let valid_second = "{\"name\":\"" + second_name + "\",\"browser_download_url\":\"" + second_url + "\",\"digest\":\"" + digest + "\"}"
  let invalid_preferred = [
    "{\"name\":\"" + first_name + "\",\"browser_download_url\":\"" + first_url + "\"}",
    "{\"name\":\"" + first_name + "\",\"browser_download_url\":null,\"digest\":\"" + digest + "\"}",
    "{\"name\":\"" + first_name + "\",\"browser_download_url\":\"https://evil.example/asset\",\"digest\":\"" + digest + "\"}",
    "{\"name\":\"" + first_name + "\",\"browser_download_url\":\"" + first_url + "\",\"digest\":\"sha512:bad\"}",
    "{\"name\":\"" + first_name + "\",\"browser_download_url\":\"" + first_url + "\",\"digest\":\"" + digest + "\"},{\"name\":\"" + first_name + "\",\"browser_download_url\":\"" + first_url + "\",\"digest\":\"" + digest + "\"}",
  ]
  for bad_entries in invalid_preferred {
    let payload = "{\"tag_name\":\"v1.0.0\",\"assets\":[" + bad_entries + "," + valid_second + "]}"
    assert_true(
      try {
        ignore(
          resolve_asset_for_release(
            payload, "acme", "tool", "tool", "tool", "tool", "1.0.0",
            "linux-x86_64", None, options,
          ),
        )
        false
      } catch {
        _ => true
      },
    )
  }
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
async test "case-folded package binaries fail before writes, including with force" {
  let root = @fs.tmpdir(prefix="moon-binstall-case-collision")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let transport = make_case_collision_transport(root)
  let probe_options = parse_batch_options([
    "acme/toolkit/cmd/first@1.2.3",
    "acme/toolkit/cmd/second@1.2.3",
    "--bin-dir",
    root + "/probe",
    "--target",
    "linux-x86_64",
  ])
  let probe_workspace = @fs.tmpdir(prefix="moon-binstall-case-probe")
  defer (@fs.rmdir(probe_workspace, recursive=true) catch { _ => () })
  let first = resolve_package(
    probe_options.coordinates[0],
    probe_options,
    "linux-x86_64",
    probe_workspace,
    0,
    Fixture(transport),
  )
  let second = resolve_package(
    probe_options.coordinates[1],
    probe_options,
    "linux-x86_64",
    probe_workspace,
    1,
    Fixture(transport),
  )
  assert_eq(first.binary, "tool")
  assert_eq(first.asset.name, "tool-linux-x86_64")
  assert_eq(second.binary, "Tool")
  assert_eq(second.asset.name, "Tool-linux-x86_64")

  for force in [false, true] {
    let output = root + (if force { "/force" } else { "/no-force" })
    if force {
      @fs.mkdir(output)
      @fs.write_file(output + "/tool", "preserve-existing\n")
    }
    let args : Array[String] = [
      "acme/toolkit/cmd/first@1.2.3", "acme/toolkit/cmd/second@1.2.3", "--bin-dir",
      output, "--target", "linux-x86_64",
    ]
    if force {
      args.push("--force")
    }
    let rejected = try {
      install_many_using(parse_batch_options(args), Fixture(transport))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
    if force {
      assert_eq(@fs.read_file(output + "/tool").text(), "preserve-existing\n")
      assert_eq(@fs.readdir(output, include_hidden=true).length(), 1)
    } else {
      assert_true(!@fs.exists(output))
    }
  }
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
