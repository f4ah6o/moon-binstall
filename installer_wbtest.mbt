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
async fn create_fixture_zip_entries(
  archive : String,
  entries : Array[(String, String)],
) -> Unit {
  let script = "import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],'w'); a=sys.argv[2:]; [z.writestr(a[i],a[i+1].encode()) for i in range(0,len(a),2)]; z.close()"
  let args : Array[String] = ["-c", script, archive]
  for (name, content) in entries {
    args.push(name)
    args.push(content)
  }
  let result = @shell.Cmd("python3", args).output()
  assert_eq(result.exit_code(), 0)
}

///|
async fn create_fixture_tar_entries(
  archive : String,
  entries : Array[(String, String)],
  format : String,
) -> Unit {
  let source = archive + ".source"
  @fs.mkdir(source, recursive=true, allow_exist=true)
  for (member_path, content) in entries {
    if member_path.has_suffix("/") {
      @fs.mkdir(source + "/" + member_path, recursive=true, allow_exist=true)
    } else {
      let parts = member_path.split("/").collect()
      let mut parent = source
      for i = 0; i < parts.length() - 1; i = i + 1 {
        parent = parent + "/" + parts[i].to_owned()
      }
      @fs.mkdir(parent, recursive=true, allow_exist=true)
      @fs.write_file(source + "/" + member_path, content)
    }
  }
  let plain = archive + ".plain.tar"
  let result = @shell.Cmd("tar", ["-cf", plain, "-C", source, "."]).output()
  assert_eq(result.exit_code(), 0)
  compress_fixture_tar(plain, archive, format)
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
    "import io, struct, sys, tarfile, zlib", "plain = io.BytesIO()", "with tarfile.open(fileobj=plain, mode='w') as archive:",
    "    member = tarfile.TarInfo('bin/fixture')", "    data = b'forged gzip fixture' + bytes([10])",
    "    member.size = len(data)", "    archive.addfile(member, io.BytesIO(data))",
    "tar_data = plain.getvalue()", "header = bytearray(bytes([31, 139, 8, 4]) + bytes(4) + bytes([0, 255]) + struct.pack('<H', 500) + bytes(500))",
    "header[148:156] = bytes([32]) * 8", "checksum = sum(header)", "header[148:156] = ('%06o' % checksum).encode() + bytes([0, 32])",
    "assert int(header[148:154], 8) == checksum", "compressor = zlib.compressobj(wbits=-15)",
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
async fn make_target_override_transport(root : String) -> FixtureTransport {
  let manifest = "{\"repository\":\"https://github.com/acme/tools\",\"packages\":[{\"package\":\"cmd/cli\",\"binary\":\"cli\",\"pkg-url\":\"{repo}/releases/download/v{version}/{bin}-{target}{archive-suffix}\",\"pkg-fmt\":\"tgz\",\"overrides\":{\"linux-x86_64\":{\"pkg-url\":\"{ repo }/releases/download/v{ version }/{ bin }-{ target }-{ target-family }{ archive-suffix }\",\"pkg-fmt\":\"tgz\",\"bin-path\":\"missing/{bin}\"},\"darwin-aarch64\":{\"pkg-url\":\"{ repo }/releases/download/v{ version }/{ bin }-{ os-name }-{ target-arch }{ archive-suffix }\",\"pkg-fmt\":\"zip\"}}}]}"
  let source_zip = root + "/target-override-source.zip"
  create_module_manifest_zip(source_zip, manifest)
  let source_digest = fixture_digest(source_zip)
  let archive = root + "/darwin-cli.zip"
  create_fixture_zip_entries(archive, [
    ("toolkit-darwin-aarch64-v1.2.3/cli", "discovered cli\n"),
  ])
  let digest = fixture_digest(archive)
  let asset_name = "cli-macos-aarch64.zip"
  let asset_url = "https://github.com/acme/tools/releases/download/v1.2.3/" +
    asset_name
  let metadata_url = "https://mooncakes.io/api/v0/manifest/acme/toolkit@1.2.3"
  let source_url = "https://download.mooncakes.io/user/acme/toolkit/1.2.3.zip"
  let metadata = "{\"module\":\"acme/toolkit\",\"version\":\"1.2.3\",\"yanked\":false,\"metadata\":{\"repository\":\"https://github.com/acme/tools\",\"checksum\":\"\{source_digest[7:].to_owned()}\"}}"
  let release_url = "https://api.github.com/repos/acme/tools/releases/tags/v1.2.3"
  let release = "{\"tag_name\":\"v1.2.3\",\"assets\":[{\"name\":\"\{asset_name}\",\"browser_download_url\":\"\{asset_url}\",\"digest\":\"\{digest}\"}]}"
  {
    responses: [(metadata_url, metadata), (release_url, release)],
    files: [(source_url, source_zip), (asset_url, archive)],
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
    glibc_min: None,
  }
  let options : BatchOptions = {
    coordinates: [],
    directory: None,
    dry_run: false,
    force: false,
    skip_compat_check: false,
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
    "tar", "tgz", "tar.gz", "tbz2", "tar.bz2", "txz", "tar.xz", "tzstd", "tar.zst",
  ]
  for i = 0; i < formats.length(); i = i + 1 {
    let format = formats[i]
    let suffix = archive_suffix(format)
    let archive = root + "/safe-" + i.to_string() + suffix
    create_fixture_tar_format(
      root + "/safe-src-" + i.to_string(),
      archive,
      content,
      "bin/fixture",
      format,
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
            archive,
            format,
            Some("bin/fixture"),
            3,
          ),
        )
        false
      } catch {
        _ => true
      },
    )

    let unsafe_archive = root + "/unsafe-" + i.to_string() + suffix
    create_unsafe_fixture_tar(
      root + "/unsafe-src-" + i.to_string(),
      unsafe_archive,
      format,
    )
    assert_true(
      try {
        ignore(
          read_artifact_binary(unsafe_archive, format, Some("bin/fixture")),
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
    root + "/gzip-src",
    gzip_archive,
    "fixture",
    "bin/fixture",
    "tgz",
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
    root + "/plain-src",
    plain_archive,
    "fixture",
    "bin/fixture",
    "tar",
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
        read_artifact_binary(forged_gzip_archive, "tar", Some("bin/fixture")),
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
  for
    name in [
      "BZh-tool", "LZIP-tool", "070701-tool", "070702-tool", "070707-tool", "MSCF-tool",
    ] {
    let archive = root + "/" + name + ".tar"
    create_fixture_tar_format(
      root + "/source-" + name,
      archive,
      content,
      name,
      "tar",
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
  let first_url = "https://github.com/acme/tool/releases/download/v1.0.0/" +
    first_name
  let second_name = "tool-darwin-aarch64.tgz"
  let second_url = "https://github.com/acme/tool/releases/download/v1.0.0/" +
    second_name
  let digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let first_asset = "{\"name\":\"" +
    first_name +
    "\",\"browser_download_url\":\"" +
    first_url +
    "\",\"digest\":\"" +
    digest +
    "\"}"
  let second_asset = "{\"name\":\"" +
    second_name +
    "\",\"browser_download_url\":\"" +
    second_url +
    "\",\"digest\":\"" +
    digest +
    "\"}"
  let only_second = "{\"tag_name\":\"v1.0.0\",\"assets\":[" +
    second_asset +
    "]}"
  let resolved_second = resolve_asset_for_release(
    only_second,
    "acme",
    "tool",
    "tool",
    "tool",
    "tool",
    "1.0.0",
    "linux-x86_64",
    None,
    options,
  )
  assert_eq(resolved_second.asset.name, second_name)
  assert_eq(resolved_second.bin_path, Some("bin/darwin-aarch64/tool"))

  let both = "{\"tag_name\":\"v1.0.0\",\"assets\":[" +
    first_asset +
    "," +
    second_asset +
    "]}"
  let resolved_first = resolve_asset_for_release(
    both,
    "acme",
    "tool",
    "tool",
    "tool",
    "tool",
    "1.0.0",
    "linux-x86_64",
    None,
    options,
  )
  assert_eq(resolved_first.asset.name, first_name)

  let unrelated_unsafe = "{\"name\":\"other-linux-x86_64.tgz\",\"browser_download_url\":\"https://evil.example/asset\",\"digest\":\"sha512:bad\"}"
  let with_unselected_unsafe = "{\"tag_name\":\"v1.0.0\",\"assets\":[" +
    unrelated_unsafe +
    "," +
    first_asset +
    "]}"
  let resolved_with_unselected_unsafe = resolve_asset_for_release(
    with_unselected_unsafe,
    "acme",
    "tool",
    "tool",
    "tool",
    "tool",
    "1.0.0",
    "linux-x86_64",
    None,
    options,
  )
  assert_eq(resolved_with_unselected_unsafe.asset.name, first_name)

  let empty = "{\"tag_name\":\"v1.0.0\",\"assets\":[]}"
  assert_true(
    try {
      ignore(
        resolve_asset_for_release(
          empty,
          "acme",
          "tool",
          "tool",
          "tool",
          "tool",
          "1.0.0",
          "linux-x86_64",
          None,
          options,
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
  let first_url = "https://github.com/acme/tool/releases/download/v1.0.0/" +
    first_name
  let second_name = "tool-darwin-aarch64.tgz"
  let second_url = "https://github.com/acme/tool/releases/download/v1.0.0/" +
    second_name
  let digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let valid_second = "{\"name\":\"" +
    second_name +
    "\",\"browser_download_url\":\"" +
    second_url +
    "\",\"digest\":\"" +
    digest +
    "\"}"
  let invalid_preferred = [
    "{\"name\":\"" +
    first_name +
    "\",\"browser_download_url\":\"" +
    first_url +
    "\"}",
    "{\"name\":\"" +
    first_name +
    "\",\"browser_download_url\":null,\"digest\":\"" +
    digest +
    "\"}",
    "{\"name\":\"" +
    first_name +
    "\",\"browser_download_url\":\"https://evil.example/asset\",\"digest\":\"" +
    digest +
    "\"}",
    "{\"name\":\"" +
    first_name +
    "\",\"browser_download_url\":\"" +
    first_url +
    "\",\"digest\":\"sha512:bad\"}",
    "{\"name\":\"" +
    first_name +
    "\",\"browser_download_url\":\"" +
    first_url +
    "\",\"digest\":\"" +
    digest +
    "\"},{\"name\":\"" +
    first_name +
    "\",\"browser_download_url\":\"" +
    first_url +
    "\",\"digest\":\"" +
    digest +
    "\"}",
  ]
  for bad_entries in invalid_preferred {
    let payload = "{\"tag_name\":\"v1.0.0\",\"assets\":[" +
      bad_entries +
      "," +
      valid_second +
      "]}"
    assert_true(
      try {
        ignore(
          resolve_asset_for_release(
            payload,
            "acme",
            "tool",
            "tool",
            "tool",
            "tool",
            "1.0.0",
            "linux-x86_64",
            None,
            options,
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
async test "archive member discovery prefers root then finds standard release directories" {
  let root = @fs.tmpdir(prefix="moon-binstall-member-discovery")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let candidates = default_archive_member_candidates(
    "toolkit", "cmd/cli", "cli", "1.2.3", "linux-x86_64",
  )
  let root_and_nested = root + "/root-and-nested.zip"
  create_fixture_zip_entries(root_and_nested, [
    ("toolkit-linux-x86_64-v1.2.3/cli", "nested binary"),
    ("cli", "root binary"),
  ])
  assert_eq(
    @utf8.decode(
      read_artifact_binary_from_candidates(root_and_nested, "zip", candidates),
    ),
    "root binary",
  )

  let nested_only = root + "/nested-only.zip"
  create_fixture_zip_entries(nested_only, [
    ("toolkit-linux-x86_64-v1.2.3/cli", "nested binary"),
  ])
  assert_eq(
    @utf8.decode(
      read_artifact_binary_from_candidates(nested_only, "zip", candidates),
    ),
    "nested binary",
  )
  let nested_tar = root + "/nested-release-directory.tgz"
  create_fixture_tar_format(
    root + "/nested-tar-source",
    nested_tar,
    "nested tar binary",
    "toolkit-linux-x86_64-v1.2.3/cli",
    "tgz",
  )
  assert_eq(
    @utf8.decode(
      read_artifact_binary_from_candidates(nested_tar, "tgz", candidates),
    ),
    "nested tar binary",
  )
  let empty_member = root + "/empty-member.zip"
  create_fixture_zip(empty_member, "cli", "")
  assert_true(
    try {
      ignore(
        read_artifact_binary_from_candidates(empty_member, "zip", candidates),
      )
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(read_artifact_binary(nested_only, "zip", Some("cli")))
      false
    } catch {
      _ => true
    },
  )

  let unsafe_unrelated = root + "/unsafe-unrelated.zip"
  create_fixture_zip_entries(unsafe_unrelated, [
    ("../escape", "unsafe"),
    ("cli", "would otherwise match"),
  ])
  assert_true(
    try {
      ignore(
        read_artifact_binary_from_candidates(
          unsafe_unrelated, "zip", candidates,
        ),
      )
      false
    } catch {
      _ => true
    },
  )
  let option_like = root + "/option-like-unrelated.zip"
  create_fixture_zip_entries(option_like, [("-x", "unsafe"), ("cli", "safe")])
  assert_true(
    try {
      ignore(
        read_artifact_binary_from_candidates(option_like, "zip", candidates),
      )
      false
    } catch {
      _ => true
    },
  )
}

///|
async test "archive discovery skips exact matching directories but explicit paths reject them" {
  let root = @fs.tmpdir(prefix="moon-binstall-matching-directory")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let target = "linux-x86_64"
  let release_dir = "tool-\{target}-v1.2.3"
  let candidates = default_archive_member_candidates(
    "tool", "cmd/main", "tool", "1.2.3", target,
  )
  for format in ["zip", "tgz"] {
    let suffix = if format == "zip" { ".zip" } else { ".tgz" }
    let root_priority = root + "/root-priority-\{format}" + suffix
    let root_entries = [
      ("tool", "root binary"),
      (release_dir + "/", ""),
      (release_dir + "/tool", "nested release binary"),
    ]
    if format == "zip" {
      create_fixture_zip_entries(root_priority, root_entries)
    } else {
      create_fixture_tar_entries(root_priority, root_entries, format)
    }
    assert_eq(
      @utf8.decode(
        read_artifact_binary_from_candidates(root_priority, format, candidates),
      ),
      "root binary",
    )

    let directory_match = root + "/directory-match-\{format}" + suffix
    let directory_entries = [
      ("tool/", ""),
      ("tool/tool", "module directory binary"),
      (release_dir + "/", ""),
      (release_dir + "/tool", "release directory binary"),
    ]
    if format == "zip" {
      create_fixture_zip_entries(directory_match, directory_entries)
    } else {
      create_fixture_tar_entries(directory_match, directory_entries, format)
    }
    assert_eq(
      @utf8.decode(
        read_artifact_binary_from_candidates(
          directory_match, format, candidates,
        ),
      ),
      "release directory binary",
    )
    let explicit_error = try {
      ignore(read_artifact_binary(directory_match, format, Some("tool")))
      ""
    } catch {
      error => error.to_string()
    }
    assert_true(
      explicit_error.contains("requested archive member is a directory"),
    )
  }
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

///|
async test "ordered target overrides select matching URL format and member path" {
  let manifest = "{\"packages\":[{\"package\":\"cmd/cli\",\"binary\":\"cli\",\"pkg-url\":\"{repo}/releases/download/v{version}/base-{target}{archive-suffix}\",\"pkg-fmt\":\"tgz\",\"bin-path\":\"base/{target}/{bin}\",\"overrides\":{\"linux-x86_64\":{\"pkg-url\":\"{ repo }/releases/download/v{ version }/linux-{ target }{ archive-suffix }\",\"pkg-fmt\":\"tgz\",\"bin-path\":\"linux/{target}/{bin}\"},\"darwin-aarch64\":{\"pkg-url\":\"{ repo }/releases/download/v{ version }/darwin-{ target }{ archive-suffix }\",\"pkg-fmt\":\"zip\",\"bin-path\":\"darwin/{target}/{bin}\"}}}]}"
  let config_set = match parse_artifact_config_set(manifest, "cmd/cli", "cli") {
    Some(value) => value
    None => fail("expected package config")
  }
  let options = parse_batch_options([
    "acme/toolkit/cmd/cli@1.2.3", "--targets", "linux-x86_64,darwin-aarch64",
  ])
  let asset_name = "darwin-darwin-aarch64.zip"
  let asset_url = "https://github.com/acme/tools/releases/download/v1.2.3/" +
    asset_name
  let digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let payload = "{\"tag_name\":\"v1.2.3\",\"assets\":[{\"name\":\"\{asset_name}\",\"browser_download_url\":\"\{asset_url}\",\"digest\":\"\{digest}\"}]}"
  let plan = resolve_asset_plan_for_release(
    payload,
    "acme",
    "tools",
    "cli",
    "toolkit",
    "cmd/cli",
    "1.2.3",
    "linux-x86_64",
    Some(config_set),
    options,
  )
  assert_eq(plan.install.asset.name, asset_name)
  assert_eq(plan.install.format, "zip")
  assert_eq(plan.install.bin_path, Some("darwin/darwin-aarch64/cli"))
  assert_true(!plan.discover_archive_member)
}

///|
async test "CLI artifact options override target metadata and explicit path never discovers" {
  let root = @fs.tmpdir(prefix="moon-binstall-cli-metadata-precedence")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let manifest = "{\"packages\":[{\"package\":\"cmd/cli\",\"binary\":\"cli\",\"pkg-url\":\"{repo}/releases/download/v{version}/base-{target}{archive-suffix}\",\"pkg-fmt\":\"tgz\",\"bin-path\":\"base/{target}/{bin}\",\"overrides\":{\"linux-x86_64\":{\"pkg-url\":\"{repo}/releases/download/v{version}/override-{target}{archive-suffix}\",\"pkg-fmt\":\"tgz\",\"bin-path\":\"override/{target}/{bin}\"}}}]}"
  let config_set = match parse_artifact_config_set(manifest, "cmd/cli", "cli") {
    Some(value) => value
    None => fail("expected package config")
  }
  let options = parse_batch_options([
    "acme/toolkit/cmd/cli@1.2.3", "--target", "linux-x86_64", "--pkg-url", "{ repo }/releases/download/v{ version }/cli-{ target }-{ archive-format }.zip",
    "--pkg-fmt", "zip", "--bin-path", "exact/{ target }/{ bin }",
  ])
  let archive = root + "/cli.zip"
  create_fixture_zip(archive, "cli", "root fallback must not be used")
  let digest = fixture_digest(archive)
  let asset_name = "cli-linux-x86_64-zip.zip"
  let asset_url = "https://github.com/acme/tools/releases/download/v1.2.3/" +
    asset_name
  let payload = "{\"tag_name\":\"v1.2.3\",\"assets\":[{\"name\":\"\{asset_name}\",\"browser_download_url\":\"\{asset_url}\",\"digest\":\"\{digest}\"}]}"
  let plan = resolve_asset_plan_for_release(
    payload,
    "acme",
    "tools",
    "cli",
    "toolkit",
    "cmd/cli",
    "1.2.3",
    "linux-x86_64",
    Some(config_set),
    options,
  )
  assert_eq(plan.install.asset.name, asset_name)
  assert_eq(plan.install.format, "zip")
  assert_eq(plan.install.bin_path, Some("exact/linux-x86_64/cli"))
  assert_true(!plan.discover_archive_member)
  let output_dir = root + "/installed"
  let workspace = root + "/workspace"
  @fs.mkdir(output_dir)
  @fs.mkdir(workspace)
  let error = try {
    ignore(
      stage_install(
        plan,
        output_dir,
        workspace,
        0,
        true,
        false,
        Fixture({ responses: [], files: [(asset_url, archive)], }),
      ),
    )
    ""
  } catch {
    error => error.to_string()
  }
  assert_true(
    error.contains(
      "archive does not contain requested binary: exact/linux-x86_64/cli",
    ),
  )
  assert_eq(@fs.readdir(output_dir, include_hidden=true).length(), 0)
  assert_eq(
    @fs.readdir(workspace, include_hidden=true).contains("asset-0"),
    true,
  )
}

///|
test "CLI URL override does not mask an invalid declared target URL" {
  let manifest = "{\"packages\":[{\"package\":\"cmd/cli\",\"binary\":\"cli\",\"pkg-url\":\"{repo}/releases/download/v{version}/{bin}-{target}\",\"pkg-fmt\":\"bin\",\"overrides\":{\"darwin-aarch64\":{\"pkg-url\":\"https://evil.example/releases/download/v{version}/cli\"}}}]}"
  let config_set = match parse_artifact_config_set(manifest, "cmd/cli", "cli") {
    Some(value) => value
    None => fail("expected package config")
  }
  let options = parse_batch_options([
    "acme/toolkit/cmd/cli@1.2.3", "--target", "linux-x86_64", "--pkg-url", "{repo}/releases/download/v{version}/{bin}-{target}",
    "--pkg-fmt", "bin",
  ])
  let asset_name = "cli-linux-x86_64"
  let asset_url = "https://github.com/acme/tools/releases/download/v1.2.3/" +
    asset_name
  let digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let payload = "{\"tag_name\":\"v1.2.3\",\"assets\":[{\"name\":\"\{asset_name}\",\"browser_download_url\":\"\{asset_url}\",\"digest\":\"\{digest}\"}]}"
  let error = try {
    ignore(
      resolve_asset_plan_for_release(
        payload,
        "acme",
        "tools",
        "cli",
        "toolkit",
        "cmd/cli",
        "1.2.3",
        "linux-x86_64",
        Some(config_set),
        options,
      ),
    )
    ""
  } catch {
    error => error.to_string()
  }
  assert_true(error.contains("pkg-url must resolve to a GitHub release asset"))
}

///|
async test "Mooncakes target fallback uses whitespace metadata and discovers nested archive binary" {
  let root = @fs.tmpdir(prefix="moon-binstall-target-override-discovery")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let output = root + "/installed"
  let options = parse_batch_options([
    "acme/toolkit/cmd/cli@1.2.3", "--targets", "linux-x86_64,darwin-aarch64", "--bin-dir",
    output,
  ])
  let transport = make_target_override_transport(root)
  install_many_using(options, Fixture(transport))
  assert_eq(@fs.read_file(output + "/cli").text(), "discovered cli\n")
  assert_true(@fs.can_execute(output + "/cli"))
  assert_eq(@fs.readdir(output, include_hidden=true).length(), 1)
}

///|
async test "second archive discovery failure preserves both forced destinations" {
  let root = @fs.tmpdir(prefix="moon-binstall-discovery-batch-failure")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let manifest = "{\"repository\":\"https://github.com/acme/tools\",\"packages\":[{\"package\":\"cmd/first\",\"binary\":\"first\",\"pkg-url\":\"{repo}/releases/download/v{version}/{bin}-{target}{archive-suffix}\",\"pkg-fmt\":\"zip\"},{\"package\":\"cmd/second\",\"binary\":\"second\",\"pkg-url\":\"{repo}/releases/download/v{version}/{bin}-{target}{archive-suffix}\",\"pkg-fmt\":\"zip\"}]}"
  let source_zip = root + "/discovery-module.zip"
  create_module_manifest_zip(source_zip, manifest)
  let source_digest = fixture_digest(source_zip)
  let first_archive = root + "/first.zip"
  create_fixture_zip_entries(first_archive, [
    ("toolkit-linux-x86_64-v1.2.3/first", "new first\n"),
  ])
  let second_archive = root + "/second.zip"
  create_fixture_zip(second_archive, "unrelated", "no executable member")
  let first_digest = fixture_digest(first_archive)
  let second_digest = fixture_digest(second_archive)
  let first_name = "first-linux-x86_64.zip"
  let second_name = "second-linux-x86_64.zip"
  let first_url = "https://github.com/acme/tools/releases/download/v1.2.3/" +
    first_name
  let second_url = "https://github.com/acme/tools/releases/download/v1.2.3/" +
    second_name
  let source_url = "https://download.mooncakes.io/user/acme/toolkit/1.2.3.zip"
  let metadata_url = "https://mooncakes.io/api/v0/manifest/acme/toolkit@1.2.3"
  let metadata = "{\"module\":\"acme/toolkit\",\"version\":\"1.2.3\",\"yanked\":false,\"metadata\":{\"repository\":\"https://github.com/acme/tools\",\"checksum\":\"\{source_digest[7:].to_owned()}\"}}"
  let release_url = "https://api.github.com/repos/acme/tools/releases/tags/v1.2.3"
  let release = "{\"tag_name\":\"v1.2.3\",\"assets\":[{\"name\":\"\{first_name}\",\"browser_download_url\":\"\{first_url}\",\"digest\":\"\{first_digest}\"},{\"name\":\"\{second_name}\",\"browser_download_url\":\"\{second_url}\",\"digest\":\"\{second_digest}\"}]}"
  let transport = FixtureTransport::{
    responses: [(metadata_url, metadata), (release_url, release)],
    files: [
      (source_url, source_zip),
      (first_url, first_archive),
      (second_url, second_archive),
    ],
  }
  let output = root + "/installed"
  @fs.mkdir(output)
  @fs.write_file(output + "/first", "old first\n")
  @fs.write_file(output + "/second", "old second\n")
  let options = parse_batch_options([
    "acme/toolkit/cmd/first@1.2.3", "acme/toolkit/cmd/second@1.2.3", "--bin-dir",
    output, "--target", "linux-x86_64", "--force",
  ])
  assert_true(
    try {
      install_many_using(options, Fixture(transport))
      false
    } catch {
      _ => true
    },
  )
  assert_eq(@fs.read_file(output + "/first").text(), "old first\n")
  assert_eq(@fs.read_file(output + "/second").text(), "old second\n")
  assert_eq(@fs.readdir(output, include_hidden=true).length(), 2)
}

///|
test "elf_machine detects little-endian ELF binaries" {
  let elf_x86_64 : Array[Byte] = [
    0x7f, b'E', b'L', b'F', 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 62, 0,
  ]
  assert_eq(elf_machine(Bytes::from_array(elf_x86_64)), Some(62))
  let elf_aarch64 : Array[Byte] = [
    0x7f, b'E', b'L', b'F', 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 183, 0,
  ]
  assert_eq(elf_machine(Bytes::from_array(elf_aarch64)), Some(183))
  assert_eq(elf_machine(Bytes::from_array([b'n', b'o', b't', b'E'])), None)
  assert_eq(elf_machine(Bytes::from_array([])), None)
  let elf_be : Array[Byte] = [
    0x7f, b'E', b'L', b'F', 2, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 62, 0,
  ]
  assert_eq(elf_machine(Bytes::from_array(elf_be)), None)
}

///|
/// Build a minimal little-endian ELF64 executable in memory: an ELF header,
/// PT_LOAD covering the whole file as an identity vaddr→offset mapping,
/// an optional PT_INTERP, and a PT_DYNAMIC section with DT_NEEDED /
/// DT_STRTAB / DT_VERNEED entries. Used to exercise parse_elf64_deps and
/// verify_binary_compat without executing anything.
fn make_test_elf64(
  machine : Int,
  etype : Int,
  interp : String?,
  needed : Array[String],
  runpath : String?,
  verneed : Array[(String, Array[String])],
  verdef : Array[String],
  rpath_tag? : Int64 = 29L,
) -> Bytes raise {
  let out : Array[Byte] = []
  fn put8(value : Int) -> Unit {
    out.push(value.to_byte())
  }
  fn put16(value : Int) -> Unit {
    put8(value & 0xff)
    put8((value >> 8) & 0xff)
  }
  fn put32(value : Int) -> Unit {
    put16(value & 0xffff)
    put16((value >> 16) & 0xffff)
  }
  fn put64(value : Int64) -> Unit {
    for i = 0; i < 8; i = i + 1 {
      put8((value >> (i * 8)).to_int() & 0xff)
    }
  }
  fn put_bytes(bytes : Array[Byte]) -> Unit {
    for b in bytes {
      out.push(b)
    }
  }
  fn put_str(text : String) -> Unit {
    for c in text {
      out.push(c.to_int().to_byte())
    }
  }

  // String table: "\0" plus every referenced name, recording offsets.
  let strtab : Array[Byte] = [0]
  let strtab_offsets : Map[String, Int] = Map([])
  fn strtab_add(name : String) -> Unit {
    if strtab_offsets.get(name) is None {
      strtab_offsets[name] = strtab.length()
      for c in name {
        strtab.push(c.to_int().to_byte())
      }
      strtab.push(0)
    }
  }
  for name in needed {
    strtab_add(name)
  }
  match runpath {
    Some(text) => strtab_add(text)
    None => ()
  }
  for entry in verneed {
    let (provider, versions) = entry
    strtab_add(provider)
    for version in versions {
      strtab_add(version)
    }
  }
  for name in verdef {
    strtab_add(name)
  }

  let verneed_len = {
    let mut len = 0
    for entry in verneed {
      let (_, versions) = entry
      len = len + 16 + 16 * versions.length()
    }
    len
  }
  let verdef_len = if verdef.is_empty() { 0 } else { 20 + 8 * verdef.length() }
  let has_dyn = needed.length() +
    verneed_len +
    verdef_len +
    (if runpath is Some(_) { 1 } else { 0 }) >
    0
  let phnum = 1 +
    (if interp is Some(_) { 1 } else { 0 }) +
    (if has_dyn { 1 } else { 0 })
  let interp_off = 64 + 56 * phnum
  let interp_len = match interp {
    Some(text) => text.length() + 1
    None => 0
  }
  let dyn_entry_count = needed.length() +
    3 +
    (if runpath is Some(_) { 1 } else { 0 }) +
    (if verneed.is_empty() { 0 } else { 2 }) +
    (if verdef.is_empty() { 0 } else { 2 })
  let dyn_off = interp_off + interp_len
  let dyn_len = 16 * dyn_entry_count
  let strtab_off = dyn_off + dyn_len
  let verneed_off = strtab_off + strtab.length()
  let verdef_off = verneed_off + verneed_len
  let total = if !has_dyn {
    interp_off + interp_len
  } else if verneed.is_empty() && verdef.is_empty() {
    verneed_off
  } else {
    verdef_off + verdef_len
  }

  // ELF header (64 bytes).
  put8(0x7f)
  put_bytes([b'E', b'L', b'F'])
  put8(2)
  put8(1)
  put8(1)
  put8(0)
  put64(0L)
  put16(etype)
  put16(machine)
  put32(1)
  put64(0L)
  put64(64L)
  put64(0L)
  put32(0)
  put16(64)
  put16(56)
  put16(phnum)
  put16(0)
  put16(0)
  put16(0)

  fn put_phdr(ptype : Int, offset : Int64, filesz : Int64) -> Unit {
    put32(ptype)
    put32(0)
    put64(offset)
    put64(offset)
    put64(0L)
    put64(filesz)
    put64(filesz)
    put64(0x1000L)
  }

  match interp {
    Some(_) => put_phdr(3, interp_off.to_int64(), interp_len.to_int64())
    None => ()
  }
  // PT_LOAD: identity vaddr == file offset over the whole file.
  put_phdr(1, 0L, total.to_int64())
  if has_dyn {
    put_phdr(2, dyn_off.to_int64(), dyn_len.to_int64())
  }

  match interp {
    Some(text) => {
      put_str(text)
      put8(0)
    }
    None => ()
  }

  if has_dyn {
    fn put_dyn(tag : Int64, value : Int64) -> Unit {
      put64(tag)
      put64(value)
    }
    for name in needed {
      put_dyn(1L, strtab_offsets[name].to_int64())
    }
    put_dyn(5L, strtab_off.to_int64())
    put_dyn(10L, strtab.length().to_int64())
    match runpath {
      Some(_) => put_dyn(rpath_tag, strtab_offsets[runpath.unwrap()].to_int64())
      None => ()
    }
    if !verneed.is_empty() {
      put_dyn(1879048190L, verneed_off.to_int64())
      put_dyn(1879048191L, verneed.length().to_int64())
    }
    if !verdef.is_empty() {
      put_dyn(1879048188L, verdef_off.to_int64())
      put_dyn(1879048189L, 1L)
    }
    put_dyn(0L, 0L)
    put_bytes(strtab)
    for pi, entry in verneed {
      let (provider, versions) = entry
      put16(1)
      put16(versions.length())
      put32(strtab_offsets[provider])
      put32(16)
      put32(
        if pi + 1 < verneed.length() {
          16 + 16 * versions.length()
        } else {
          0
        },
      )
      for j, version in versions {
        put32(0)
        put16(0)
        put16(j + 2)
        put32(strtab_offsets[version])
        put32(if j + 1 < versions.length() { 16 } else { 0 })
      }
    }
    if !verdef.is_empty() {
      put16(1)
      put16(0)
      put16(1)
      put16(verdef.length())
      put32(0)
      put32(20)
      put32(0)
      for j, name in verdef {
        put32(strtab_offsets[name])
        put32(if j + 1 < verdef.length() { 8 } else { 0 })
      }
    }
  }
  if out.length() != total {
    fail("test ELF size mismatch")
  }
  Bytes::from_array(out)
}

///|
test "parse_elf64_deps extracts interp, needed, runpath and versions" {
  let elf = make_test_elf64(
    62,
    2,
    Some("/lib64/ld-linux-x86-64.so.2"),
    ["libc.so.6", "libm.so.6"],
    Some("$ORIGIN/lib"),
    [("libc.so.6", ["GLIBC_2.34", "GLIBC_2.38"])],
    [],
  )
  let deps = parse_elf64_deps(elf).unwrap()
  assert_eq(deps.interp, Some("/lib64/ld-linux-x86-64.so.2"))
  assert_eq(deps.needed, ["libc.so.6", "libm.so.6"])
  assert_eq(deps.runpath, Some("$ORIGIN/lib"))
  assert_eq(deps.verneed, [
    ("libc.so.6", "GLIBC_2.34"),
    ("libc.so.6", "GLIBC_2.38"),
  ])
  let libelf = make_test_elf64(62, 3, None, [], None, [], ["GLIBCXX_3.4.21"])
  let libdeps = parse_elf64_deps(libelf).unwrap()
  assert_eq(libdeps.verdef, ["GLIBCXX_3.4.21"])
  let static_elf = make_test_elf64(62, 2, None, [], None, [], [])
  let static_deps = parse_elf64_deps(static_elf).unwrap()
  assert_eq(static_deps.interp, None)
  assert_eq(static_deps.needed, [])
  assert_eq(static_deps.verneed, [])
  assert_true(parse_elf64_deps(Bytes::from_array([b'n', b'o'])) is None)
  // A 32-bit ELF is not parsed for dependencies.
  let elf32 : Array[Byte] = [
    0x7f, b'E', b'L', b'F', 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  ]
  assert_true(parse_elf64_deps(Bytes::from_array(elf32)) is None)
}

///|
test "expand_runpath expands $ORIGIN and drops unexpandable entries" {
  let tokens = ["lib/x86_64-linux-gnu"]
  assert_eq(expand_runpath(None, "/opt/bin", tokens), [])
  assert_eq(
    expand_runpath(
      Some("$ORIGIN:$ORIGIN/lib:/abs/lib:$LIB:rel/lib"),
      "/opt/bin",
      tokens,
    ),
    ["/opt/bin", "/opt/bin/lib", "/abs/lib"],
  )
  // The braced ${ORIGIN} form is equivalent for the glibc loader.
  assert_eq(
    expand_runpath(Some("${ORIGIN}:${ORIGIN}/lib"), "/opt/bin", tokens),
    ["/opt/bin", "/opt/bin/lib"],
  )
}

///|
async test "expand_runpath expands $LIB to the host's single value" {
  guard require_platform() == "linux-x86_64" else { return }
  // glibc substitutes exactly one distro-specific value for $LIB:
  // lib/<triplet> on Debian multiarch, lib64 on Fedora-style layouts.
  let tokens = lib_token_names(62)
  assert_eq(tokens.length(), 1)
  let token = tokens[0]
  assert_true(
    token == "lib/x86_64-linux-gnu" || token == "lib64" || token == "lib",
  )
  // Under an absolute anchor the single expansion produces exactly one
  // candidate directory — other plausible-but-wrong dirs must not be
  // searched (a library only under lib64 fails on Debian).
  assert_eq(expand_runpath(Some("$ORIGIN/$LIB"), "/opt/bin", tokens), [
    "/opt/bin/" + token,
  ])
  // The braced ${LIB} form expands the same way.
  assert_eq(expand_runpath(Some("${ORIGIN}/${LIB}"), "/opt/bin", tokens), [
    "/opt/bin/" + token,
  ])
  // A bare $LIB entry is relative and stays unusable; $PLATFORM is not
  // emulated and is dropped.
  assert_eq(
    expand_runpath(Some("$LIB:$ORIGIN/$PLATFORM"), "/opt/bin", tokens),
    [],
  )
}

///|
async test "verify_binary_compat rejects a missing ELF interpreter on linux" {
  guard require_platform() == "linux-x86_64" else { return }
  let elf = make_test_elf64(
    62,
    2,
    Some("/nonexistent/ld-binstall-missing.so"),
    [],
    None,
    [],
    [],
  )
  let error = try {
    verify_binary_compat("/tmp/staged-dsh", elf, false, "/tmp")
    ""
  } catch {
    error => error.to_string()
  }
  assert_true(error.contains("ELF interpreter"))
  assert_true(error.contains("/nonexistent/ld-binstall-missing.so"))
  // A foreign-architecture ELF with the same bogus interpreter is skipped.
  let foreign = make_test_elf64(
    183,
    2,
    Some("/nonexistent/ld-binstall-missing.so"),
    [],
    None,
    [],
    [],
  )
  verify_binary_compat("/tmp/staged-dsh-arm", foreign, false, "/tmp")
}

///|
async test "verify_binary_compat rejects non-executable and malformed ELF" {
  guard require_platform() == "linux-x86_64" else { return }
  // A relocatable object (ET_REL) like `gcc -c` output is not executable.
  let object = make_test_elf64(62, 1, None, [], None, [], [])
  let error = try {
    verify_binary_compat("/tmp/object.o", object, false, "/tmp")
    ""
  } catch {
    error => error.to_string()
  }
  assert_true(error.contains("not executable"))
  // An ET_EXEC with zero program headers is malformed and must fail closed.
  let header : Array[Byte] = [
    0x7f, b'E', b'L', b'F', 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 62, 0,
  ]
  let bytes = header
  for i = 0; i < 44; i = i + 1 {
    bytes.push(0)
  }
  let malformed = try {
    verify_binary_compat("/tmp/stub", Bytes::from_array(bytes), false, "/tmp")
    ""
  } catch {
    error => error.to_string()
  }
  assert_true(malformed.contains("malformed"))
  // A dynamic binary without PT_INTERP cannot load its libraries.
  let no_interp = make_test_elf64(62, 2, None, ["libc.so.6"], None, [], [])
  let error2 = try {
    verify_binary_compat("/tmp/staged", no_interp, false, "/tmp")
    ""
  } catch {
    error => error.to_string()
  }
  assert_true(error2.contains("no ELF interpreter"))
}

///|
/// Stage a usable PT_INTERP stand-in: an executable host-architecture
/// ET_DYN ELF, matching what the kernel accepts as a loader.
async fn staged_loader(dir : String) -> String {
  let path = dir + "/ld-binstall-test.so.2"
  @fs.write_file(path, make_test_elf64(62, 3, None, [], None, [], []))
  @fs.chmod(path, 0o755)
  path
}

///|
async test "verify_binary_compat rejects unresolved libraries on linux" {
  guard require_platform() == "linux-x86_64" else { return }
  let install_dir = @fs.tmpdir(prefix="moon-binstall-missing")
  defer (@fs.rmdir(install_dir, recursive=true) catch { _ => () })
  let loader = staged_loader(install_dir)
  let elf = make_test_elf64(
    62,
    2,
    Some(loader),
    ["libdefinitelymissing99.so.1"],
    None,
    [],
    [],
  )
  let error = try {
    verify_binary_compat("/tmp/staged-dsh", elf, false, install_dir)
    ""
  } catch {
    error => error.to_string()
  }
  assert_true(error.contains("unresolved libraries"))
  assert_true(error.contains("libdefinitelymissing99.so.1"))
}

///|
async test "verify_binary_compat honors RUNPATH $ORIGIN on linux" {
  guard require_platform() == "linux-x86_64" else { return }
  let install_dir = @fs.tmpdir(prefix="moon-binstall-rpath")
  defer (@fs.rmdir(install_dir, recursive=true) catch { _ => () })
  // A private library beside the installed binary must itself be a usable
  // host-architecture shared object.
  let lib = make_test_elf64(62, 3, None, [], None, [], [])
  @fs.write_file(install_dir + "/libfake99.so", lib)
  let loader = staged_loader(install_dir)
  let elf = make_test_elf64(
    62,
    2,
    Some(loader),
    ["libfake99.so"],
    Some("$ORIGIN"),
    [],
    [],
  )
  verify_binary_compat("/tmp/staged-app", elf, false, install_dir)
  // Without the rpath hit the same soname is missing.
  let no_rpath = make_test_elf64(
    62,
    2,
    Some(loader),
    ["libfake99.so"],
    None,
    [],
    [],
  )
  let error = try {
    verify_binary_compat("/tmp/staged-app", no_rpath, false, install_dir)
    ""
  } catch {
    error => error.to_string()
  }
  assert_true(error.contains("libfake99.so"))
  // The braced ${ORIGIN} form resolves the same way.
  let braced = make_test_elf64(
    62,
    2,
    Some(loader),
    ["libfake99.so"],
    Some("${ORIGIN}"),
    [],
    [],
  )
  verify_binary_compat("/tmp/staged-app", braced, false, install_dir)
}

///|
async test "verify_binary_compat rejects an unusable ELF interpreter" {
  guard require_platform() == "linux-x86_64" else { return }
  let install_dir = @fs.tmpdir(prefix="moon-binstall-interp")
  defer (@fs.rmdir(install_dir, recursive=true) catch { _ => () })
  let lib = make_test_elf64(62, 3, None, [], None, [], [])
  @fs.write_file(install_dir + "/libfake99.so", lib)
  // Case 1: an existing non-ELF, non-executable text file.
  let text_loader = install_dir + "/fake-loader"
  @fs.write_file(text_loader, "just text\n")
  let elf = make_test_elf64(
    62,
    2,
    Some(text_loader),
    ["libfake99.so"],
    Some("$ORIGIN"),
    [],
    [],
  )
  let error = try {
    verify_binary_compat("/tmp/staged-app", elf, false, install_dir)
    ""
  } catch {
    error => error.to_string()
  }
  assert_true(error.contains("ELF interpreter"))
  // Case 2: a proper ELF loader without the executable bit.
  let noexec_loader = install_dir + "/ld-noexec.so.2"
  @fs.write_file(noexec_loader, make_test_elf64(62, 3, None, [], None, [], []))
  @fs.chmod(noexec_loader, 0o644)
  let elf2 = make_test_elf64(
    62,
    2,
    Some(noexec_loader),
    ["libfake99.so"],
    Some("$ORIGIN"),
    [],
    [],
  )
  let error2 = try {
    verify_binary_compat("/tmp/staged-app", elf2, false, install_dir)
    ""
  } catch {
    error => error.to_string()
  }
  assert_true(error2.contains("ELF interpreter"))
  // Case 3: a foreign-architecture loader is not usable either.
  let arm_loader = install_dir + "/ld-arm.so.2"
  @fs.write_file(arm_loader, make_test_elf64(183, 3, None, [], None, [], []))
  @fs.chmod(arm_loader, 0o755)
  let elf3 = make_test_elf64(
    62,
    2,
    Some(arm_loader),
    ["libfake99.so"],
    Some("$ORIGIN"),
    [],
    [],
  )
  let error3 = try {
    verify_binary_compat("/tmp/staged-app", elf3, false, install_dir)
    ""
  } catch {
    error => error.to_string()
  }
  assert_true(error3.contains("ELF interpreter"))
  // Case 4: a truncated ELF — only the first bytes of a real-looking
  // loader — is not loadable even with the executable bit set.
  let short_loader = install_dir + "/ld-short.so.2"
  let whole = make_test_elf64(62, 3, None, [], None, [], [])
  @fs.write_file(short_loader, whole[:20].to_owned())
  @fs.chmod(short_loader, 0o755)
  let elf4 = make_test_elf64(
    62,
    2,
    Some(short_loader),
    ["libfake99.so"],
    Some("$ORIGIN"),
    [],
    [],
  )
  let error4 = try {
    verify_binary_compat("/tmp/staged-app", elf4, false, install_dir)
    ""
  } catch {
    error => error.to_string()
  }
  assert_true(error4.contains("ELF interpreter"))
}

///|
async test "verify_binary_compat rejects a wrong-architecture provider" {
  guard require_platform() == "linux-x86_64" else { return }
  let install_dir = @fs.tmpdir(prefix="moon-binstall-wrongarch")
  defer (@fs.rmdir(install_dir, recursive=true) catch { _ => () })
  let loader = staged_loader(install_dir)
  // The provider resolves via $ORIGIN but is built for AArch64.
  let arm_lib = make_test_elf64(183, 3, None, [], None, [], [])
  @fs.write_file(install_dir + "/libfake99.so", arm_lib)
  let elf = make_test_elf64(
    62,
    2,
    Some(loader),
    ["libfake99.so"],
    Some("$ORIGIN"),
    [],
    [],
  )
  let error = try {
    verify_binary_compat("/tmp/staged-app", elf, false, install_dir)
    ""
  } catch {
    error => error.to_string()
  }
  assert_true(error.contains("unusable libraries"))
  assert_true(error.contains("libfake99.so"))
  // A non-ELF file at the resolved path is equally unusable.
  @fs.write_file(install_dir + "/libfake99.so", "not an elf\n")
  let error2 = try {
    verify_binary_compat("/tmp/staged-app", elf, false, install_dir)
    ""
  } catch {
    error => error.to_string()
  }
  assert_true(error2.contains("unusable libraries"))
}

///|
async test "resolve_soname prefers a usable ldconfig candidate" {
  guard require_platform() == "linux-x86_64" else { return }
  let dir = @fs.tmpdir(prefix="moon-binstall-cache")
  defer (@fs.rmdir(dir, recursive=true) catch { _ => () })
  // The cache lists both an i386 and an x86_64 provider for one soname —
  // the loader picks the ABI-compatible entry regardless of order.
  let i386 = dir + "/libc32.so"
  let x64 = dir + "/libc64.so"
  @fs.write_file(i386, make_test_elf64(3, 3, None, [], None, [], []))
  @fs.write_file(x64, make_test_elf64(62, 3, None, [], None, [], []))
  let cache : Map[String, Array[String]] = Map([])
  cache["libdup.so.1"] = [i386, x64]
  let found = resolve_soname("libdup.so.1", [], cache, [], 62)
  assert_eq(found, Some(x64))
  cache["libdup.so.1"] = [x64, i386]
  let found2 = resolve_soname("libdup.so.1", [], cache, [], 62)
  assert_eq(found2, Some(x64))
  // With only a wrong-architecture candidate the resolution still reports
  // a path so the caller can reject it as unusable.
  cache["libdup.so.1"] = [i386]
  let found3 = resolve_soname("libdup.so.1", [], cache, [], 62)
  assert_eq(found3, Some(i386))
}

///|
async test "resolve_soname refuses a non-regular DT_NEEDED path" {
  guard require_platform() == "linux-x86_64" else { return }
  let dir = @fs.tmpdir(prefix="moon-binstall-fifo")
  defer (@fs.rmdir(dir, recursive=true) catch { _ => () })
  let fifo = dir + "/libfifo.so"
  let status = @process.run("mkfifo", [fifo])
  guard status == 0 else { return }
  // An absolute-path DT_NEEDED naming a FIFO must not be opened.
  let found = resolve_soname(fifo, [], Map([]), [], 62)
  assert_true(found is None)
  // ...nor picked up from a search directory.
  let found2 = resolve_soname("libfifo.so", [dir], Map([]), [], 62)
  assert_true(found2 is None)
}

///|
async test "verify_binary_compat honors LD_LIBRARY_PATH on linux" {
  guard require_platform() == "linux-x86_64" else { return }
  let install_dir = @fs.tmpdir(prefix="moon-binstall-ldlib")
  let lib_dir = @fs.tmpdir(prefix="moon-binstall-ldlibdep")
  defer (@fs.rmdir(install_dir, recursive=true) catch { _ => () })
  defer (@fs.rmdir(lib_dir, recursive=true) catch { _ => () })
  defer @env.unset_env_var("LD_LIBRARY_PATH")
  let loader = staged_loader(install_dir)
  let lib = make_test_elf64(62, 3, None, [], None, [], [])
  @fs.write_file(lib_dir + "/libenvdep.so", lib)
  // No RUNPATH: only the inherited LD_LIBRARY_PATH makes this runnable.
  @env.set_env_var("LD_LIBRARY_PATH", lib_dir)
  let elf = make_test_elf64(62, 2, Some(loader), ["libenvdep.so"], None, [], [])
  verify_binary_compat("/tmp/staged-app", elf, false, install_dir)
  // The dependency is genuinely missing once LD_LIBRARY_PATH is empty.
  @env.unset_env_var("LD_LIBRARY_PATH")
  let error = try {
    verify_binary_compat("/tmp/staged-app", elf, false, install_dir)
    ""
  } catch {
    error => error.to_string()
  }
  assert_true(error.contains("libenvdep.so"))
}

///|
async test "resolve_soname skips an incompatible search-dir candidate" {
  guard require_platform() == "linux-x86_64" else { return }
  let wrong_dir = @fs.tmpdir(prefix="moon-binstall-abi-wrong")
  let good_dir = @fs.tmpdir(prefix="moon-binstall-abi-good")
  defer (@fs.rmdir(wrong_dir, recursive=true) catch { _ => () })
  defer (@fs.rmdir(good_dir, recursive=true) catch { _ => () })
  // The same soname exists in two search directories; glibc skips the
  // AArch64 file and loads the x86_64 one regardless of directory order.
  let wrong = wrong_dir + "/libdup.so.1"
  let good = good_dir + "/libdup.so.1"
  @fs.write_file(wrong, make_test_elf64(183, 3, None, [], None, [], []))
  @fs.write_file(good, make_test_elf64(62, 3, None, [], None, [], []))
  let found = resolve_soname(
    "libdup.so.1",
    [wrong_dir, good_dir],
    Map([]),
    [],
    62,
  )
  assert_eq(found, Some(good))
  let found2 = resolve_soname(
    "libdup.so.1",
    [good_dir, wrong_dir],
    Map([]),
    [],
    62,
  )
  assert_eq(found2, Some(good))
  // When every candidate is unusable the first is still reported so the
  // caller can reject it as an unusable library.
  let found3 = resolve_soname("libdup.so.1", [wrong_dir], Map([]), [], 62)
  assert_eq(found3, Some(wrong))
}

///|
async test "verify_binary_compat honors a $LIB RUNPATH on linux" {
  guard require_platform() == "linux-x86_64" else { return }
  let install_dir = @fs.tmpdir(prefix="moon-binstall-libtoken")
  defer (@fs.rmdir(install_dir, recursive=true) catch { _ => () })
  let loader = staged_loader(install_dir)
  // A private library under the host's single $LIB expansion satisfies
  // RUNPATH="$ORIGIN/$LIB".
  let token = lib_token_names(62)[0]
  let lib_dir = install_dir + "/" + token
  @fs.mkdir(lib_dir, recursive=true)
  @fs.write_file(
    lib_dir + "/libtokdep.so",
    make_test_elf64(62, 3, None, [], None, [], []),
  )
  let elf = make_test_elf64(
    62,
    2,
    Some(loader),
    ["libtokdep.so"],
    Some("$ORIGIN/$LIB"),
    [],
    [],
  )
  verify_binary_compat("/tmp/staged-app", elf, false, install_dir)
  // Negative: the same library placed in a directory the real loader's
  // $LIB expansion does NOT name must not satisfy the RUNPATH — other
  // plausible-but-wrong dirs are not searched (Debian repro).
  let wrong_dir = install_dir + "/libnotoken"
  @fs.mkdir(wrong_dir, recursive=true)
  @fs.write_file(
    wrong_dir + "/libonlywrong.so",
    make_test_elf64(62, 3, None, [], None, [], []),
  )
  let wrong = make_test_elf64(
    62,
    2,
    Some(loader),
    ["libonlywrong.so"],
    Some("$ORIGIN/$LIB"),
    [],
    [],
  )
  let error = try {
    verify_binary_compat("/tmp/staged-app", wrong, false, install_dir)
    ""
  } catch {
    error => error.to_string()
  }
  assert_true(error.contains("libonlywrong.so"))
}

///|
async test "resolve_soname keeps searching later tiers after an unusable hit" {
  guard require_platform() == "linux-x86_64" else { return }
  let wrong_dir = @fs.tmpdir(prefix="moon-binstall-tier-wrong")
  let good_dir = @fs.tmpdir(prefix="moon-binstall-tier-good")
  defer (@fs.rmdir(wrong_dir, recursive=true) catch { _ => () })
  defer (@fs.rmdir(good_dir, recursive=true) catch { _ => () })
  // LD_LIBRARY_PATH names only an AArch64 file; the ldconfig cache holds
  // the compatible x86_64 one. glibc skips the foreign object and uses
  // the system library — the unusable hit must not shadow the next tier.
  let wrong = wrong_dir + "/libdup.so.1"
  let good = good_dir + "/libdup.so.1"
  @fs.write_file(wrong, make_test_elf64(183, 3, None, [], None, [], []))
  @fs.write_file(good, make_test_elf64(62, 3, None, [], None, [], []))
  let cache : Map[String, Array[String]] = Map([])
  cache["libdup.so.1"] = [good]
  let found = resolve_soname("libdup.so.1", [wrong_dir], cache, [], 62)
  assert_eq(found, Some(good))
  // Cross-tier all-unusable still falls back to the first regular file
  // so the caller can reject it as unusable.
  cache["libdup.so.1"] = [wrong]
  let found2 = resolve_soname(
    "libdup.so.1",
    [good_dir, wrong_dir],
    cache,
    [],
    62,
  )
  assert_eq(found2, Some(good))
  let found3 = resolve_soname("libdup.so.1", [wrong_dir], Map([]), [], 62)
  assert_eq(found3, Some(wrong))
}

///|
async test "verify_binary_compat inherits DT_RPATH transitively on linux" {
  guard require_platform() == "linux-x86_64" else { return }
  let install_dir = @fs.tmpdir(prefix="moon-binstall-rpath-inherit")
  defer (@fs.rmdir(install_dir, recursive=true) catch { _ => () })
  let loader = staged_loader(install_dir)
  // main -> libfoo -> libbar, all colocated: only main carries a legacy
  // DT_RPATH ($ORIGIN), and glibc propagates it to libfoo's lookups.
  @fs.write_file(
    install_dir + "/libfoo.so.1",
    make_test_elf64(62, 3, None, ["libbar.so.1"], None, [], []),
  )
  @fs.write_file(
    install_dir + "/libbar.so.1",
    make_test_elf64(62, 3, None, [], None, [], []),
  )
  let elf = make_test_elf64(
    62,
    2,
    Some(loader),
    ["libfoo.so.1"],
    Some("$ORIGIN"),
    [],
    [],
    rpath_tag=15L,
  )
  verify_binary_compat("/tmp/staged-app", elf, false, install_dir)
  // DT_RUNPATH does NOT propagate: with tag 29 instead the same chain
  // leaves libbar unresolvable.
  let no_inherit = make_test_elf64(
    62,
    2,
    Some(loader),
    ["libfoo.so.1"],
    Some("$ORIGIN"),
    [],
    [],
  )
  let error = try {
    verify_binary_compat("/tmp/staged-app", no_inherit, false, install_dir)
    ""
  } catch {
    error => error.to_string()
  }
  assert_true(error.contains("libbar.so.1"))
}

///|
async test "verify_binary_compat reuses an already-loaded library on linux" {
  guard require_platform() == "linux-x86_64" else { return }
  let install_dir = @fs.tmpdir(prefix="moon-binstall-reuse")
  defer (@fs.rmdir(install_dir, recursive=true) catch { _ => () })
  let loader = staged_loader(install_dir)
  // main directly needs BOTH libfoo and libbar via DT_RUNPATH=$ORIGIN;
  // libfoo itself needs libbar but carries no RUNPATH. ld.so loads libbar
  // while handling the executable, so libfoo's lookup reuses the mapped
  // object without searching — libfoo's narrower context is irrelevant.
  @fs.write_file(
    install_dir + "/libfooreuse.so.1",
    make_test_elf64(62, 3, None, ["libbarreuse.so.1"], None, [], []),
  )
  @fs.write_file(
    install_dir + "/libbarreuse.so.1",
    make_test_elf64(62, 3, None, [], None, [], []),
  )
  let elf = make_test_elf64(
    62,
    2,
    Some(loader),
    ["libfooreuse.so.1", "libbarreuse.so.1"],
    Some("$ORIGIN"),
    [],
    [],
  )
  verify_binary_compat("/tmp/staged-app", elf, false, install_dir)
  // Genuinely missing: without libbar anywhere the chain must still fail.
  @fs.remove(install_dir + "/libbarreuse.so.1")
  let error = try {
    verify_binary_compat("/tmp/staged-app", elf, false, install_dir)
    ""
  } catch {
    error => error.to_string()
  }
  assert_true(error.contains("libbarreuse.so.1"))
}

///|
async test "verify_binary_compat checks transitive dependencies on linux" {
  guard require_platform() == "linux-x86_64" else { return }
  let install_dir = @fs.tmpdir(prefix="moon-binstall-transitive")
  defer (@fs.rmdir(install_dir, recursive=true) catch { _ => () })
  let loader = staged_loader(install_dir)
  // libfoo.so.1 resolves beside the binary but itself needs libbar.so.1.
  @fs.write_file(
    install_dir + "/libfoo.so.1",
    make_test_elf64(62, 3, None, ["libbar.so.1"], Some("$ORIGIN"), [], []),
  )
  let elf = make_test_elf64(
    62,
    2,
    Some(loader),
    ["libfoo.so.1"],
    Some("$ORIGIN"),
    [],
    [],
  )
  // libbar missing: the loader would fail at startup, so must we.
  let error = try {
    verify_binary_compat("/tmp/staged-app", elf, false, install_dir)
    ""
  } catch {
    error => error.to_string()
  }
  assert_true(error.contains("libbar.so.1"))
  // With libbar staged beside libfoo (its own $ORIGIN), the chain holds.
  @fs.write_file(
    install_dir + "/libbar.so.1",
    make_test_elf64(62, 3, None, [], None, [], []),
  )
  verify_binary_compat("/tmp/staged-app", elf, false, install_dir)
}

///|
test "ld_library_dirs keeps absolute entries only" {
  assert_eq(ld_library_dirs(Some("/a:/b::rel/lib:$ORIGIN:/c ")), [
    "/a", "/b", "/c",
  ])
  assert_eq(ld_library_dirs(None), [])
  assert_eq(ld_library_dirs(Some("")), [])
}

///|
async test "verify_binary_compat checks required symbol versions on linux" {
  guard require_platform() == "linux-x86_64" else { return }
  let install_dir = @fs.tmpdir(prefix="moon-binstall-versions")
  defer (@fs.rmdir(install_dir, recursive=true) catch { _ => () })
  let loader = staged_loader(install_dir)
  // A provider library that defines only GLIBC_2.2.5.
  let provider = make_test_elf64(62, 3, None, [], None, [], ["GLIBC_2.2.5"])
  @fs.write_file(install_dir + "/libfakec.so.6", provider)
  // GLIBC_99.0 is not defined by the provider: rejected via its verdef.
  let elf = make_test_elf64(
    62,
    2,
    Some(loader),
    ["libfakec.so.6"],
    Some("$ORIGIN"),
    [("libfakec.so.6", ["GLIBC_99.0"])],
    [],
  )
  let error = try {
    verify_binary_compat("/tmp/staged-dsh", elf, false, install_dir)
    ""
  } catch {
    error => error.to_string()
  }
  assert_true(error.contains("GLIBC_99.0"))
  assert_true(error.contains("does not provide"))
  // A requirement the provider does define installs fine.
  let healthy = make_test_elf64(
    62,
    2,
    Some(loader),
    ["libfakec.so.6"],
    Some("$ORIGIN"),
    [("libfakec.so.6", ["GLIBC_2.2.5"])],
    [],
  )
  verify_binary_compat("/tmp/staged-cli", healthy, false, install_dir)
}

///|
async test "verify_binary_compat checks non-GLIBC versions on linux" {
  guard require_platform() == "linux-x86_64" else { return }
  let install_dir = @fs.tmpdir(prefix="moon-binstall-glibcxx")
  defer (@fs.rmdir(install_dir, recursive=true) catch { _ => () })
  let loader = staged_loader(install_dir)
  // A provider library that defines GLIBCXX_3.4.21 but not GLIBCXX_9.9.99.
  let provider = make_test_elf64(62, 3, None, [], None, [], ["GLIBCXX_3.4.21"])
  @fs.write_file(install_dir + "/libfakexx.so.6", provider)
  let elf = make_test_elf64(
    62,
    2,
    Some(loader),
    ["libfakexx.so.6"],
    Some("$ORIGIN"),
    [("libfakexx.so.6", ["GLIBCXX_9.9.99"])],
    [],
  )
  let error = try {
    verify_binary_compat("/tmp/staged-app", elf, false, install_dir)
    ""
  } catch {
    error => error.to_string()
  }
  assert_true(error.contains("GLIBCXX_9.9.99"))
  // A requirement the provider does define installs fine.
  let ok = make_test_elf64(
    62,
    2,
    Some(loader),
    ["libfakexx.so.6"],
    Some("$ORIGIN"),
    [("libfakexx.so.6", ["GLIBCXX_3.4.21"])],
    [],
  )
  verify_binary_compat("/tmp/staged-app", ok, false, install_dir)
}

///|
test "parse_host_libc detects gnu and musl systems" {
  assert_eq(
    parse_host_libc("ldd (Ubuntu GLIBC 2.35-0ubuntu3.14) 2.35\nCopyright\n"),
    Some("2.35"),
  )
  assert_eq(
    parse_host_libc("musl libc (x86_64)\nVersion 1.2.5\n"),
    Some("musl"),
  )
  assert_eq(parse_host_libc(""), None)
}

///|
test "version_lt compares dotted numeric versions" {
  assert_true(version_lt("2.35", "2.38"))
  assert_true(version_lt("2.9", "2.35"))
  assert_true(!version_lt("2.38", "2.38"))
  assert_true(!version_lt("2.38.1", "2.38"))
  assert_true(version_lt("2.38", "2.38.1"))
}

///|
test "manifest glibc-min is parsed and validated" {
  let manifest = "{\"repository\":\"https://github.com/acme/tools\",\"packages\":[{\"package\":\"cmd/cli\",\"binary\":\"cli\",\"glibc-min\":\"2.38\"}]}"
  let config = parse_artifact_config(manifest, "cmd/cli", "cli")
  assert_eq(config.unwrap().glibc_min, Some("2.38"))
  let bad = "{\"repository\":\"https://github.com/acme/tools\",\"packages\":[{\"package\":\"cmd/cli\",\"glibc-min\":\"latest\"}]}"
  assert_true(
    try {
      ignore(parse_artifact_config(bad, "cmd/cli", "cli"))
      false
    } catch {
      _ => true
    },
  )
  let override_manifest = "{\"repository\":\"https://github.com/acme/tools\",\"packages\":[{\"package\":\"cmd/cli\",\"binary\":\"cli\",\"pkg-fmt\":\"bin\",\"overrides\":{\"linux-x86_64\":{\"glibc-min\":\"2.38\"}}}]}"
  let set = parse_artifact_config_set(override_manifest, "cmd/cli", "cli")
  assert_eq(
    artifact_config_for_target(set.unwrap(), "linux-x86_64").glibc_min,
    Some("2.38"),
  )
  assert_eq(
    artifact_config_for_target(set.unwrap(), "darwin-aarch64").glibc_min,
    None,
  )
}

///|
async test "declared glibc-min aborts install before download on linux" {
  guard require_platform().has_prefix("linux") else { return }
  let root = @fs.tmpdir(prefix="moon-binstall-glibc-min")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let manifest = "{\"repository\":\"https://github.com/acme/tools\",\"version\":\"1.2.3\",\"packages\":[{\"package\":\"cmd/cli\",\"binary\":\"cli\",\"glibc-min\":\"99.0\"}]}"
  let manifest_path = root + "/moon-binstall.json"
  @fs.write_file(manifest_path, manifest)
  let full_transport = make_registry_fixture_transport(root, false)
  let transport = FixtureTransport::{
    responses: [full_transport.responses[2]],
    files: [],
  }
  let options = parse_batch_options([
    "acme/toolkit/cmd/cli@1.2.3",
    "--manifest-path",
    manifest_path,
    "--bin-dir",
    root + "/installed",
    "--target",
    "linux-x86_64",
  ])
  let error = try {
    install_many_using(options, Fixture(transport))
    ""
  } catch {
    error => error.to_string()
  }
  assert_true(error.contains("requires glibc >= 99.0"))
  assert_true(!@fs.exists(root + "/installed/cli"))
}

///|
async test "declared glibc-min does not apply to a cross-architecture fetch" {
  guard require_platform() == "linux-x86_64" else { return }
  let root = @fs.tmpdir(prefix="moon-binstall-cross-glibc")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let manifest = "{\"repository\":\"https://github.com/acme/tools\",\"version\":\"1.2.3\",\"packages\":[{\"package\":\"cmd/cli\",\"binary\":\"cli\",\"glibc-min\":\"99.0\",\"pkg-url\":\"{repo}/releases/download/v{version}/{bin}-{target}\",\"pkg-fmt\":\"bin\"}]}"
  let manifest_path = root + "/moon-binstall.json"
  @fs.write_file(manifest_path, manifest)
  let arm_asset = root + "/cli-linux-aarch64"
  @fs.write_file(arm_asset, "arm64 payload\n")
  let arm_digest = fixture_digest(arm_asset)
  let asset_url = "https://github.com/acme/tools/releases/download/v1.2.3/cli-linux-aarch64"
  let release_url = "https://api.github.com/repos/acme/tools/releases/tags/v1.2.3"
  let release = "{\"tag_name\":\"v1.2.3\",\"assets\":[{\"name\":\"cli-linux-aarch64\",\"browser_download_url\":\"\{asset_url}\",\"digest\":\"\{arm_digest}\"}]}"
  let transport = FixtureTransport::{
    responses: [(release_url, release)],
    files: [(asset_url, arm_asset)],
  }
  let options = parse_batch_options([
    "acme/toolkit/cmd/cli@1.2.3",
    "--manifest-path",
    manifest_path,
    "--bin-dir",
    root + "/installed",
    "--target",
    "linux-aarch64",
  ])
  install_many_using(options, Fixture(transport))
  assert_eq(@fs.read_file(root + "/installed/cli").text(), "arm64 payload\n")
}

///|
async test "elf_file_usable accepts a full ELF and a symlink to it" {
  guard require_platform() == "linux-x86_64" else { return }
  let dir = @fs.tmpdir(prefix="moon-binstall-usable")
  defer (@fs.rmdir(dir, recursive=true) catch { _ => () })
  let loader = dir + "/ld-real.so.2"
  @fs.write_file(loader, make_test_elf64(62, 3, None, [], None, [], []))
  assert_true(elf_file_usable(loader, 62))
  // Distros link /lib64/ld-linux through a symlink: the target's type,
  // permissions and size must be inspected, never the link's lstat size.
  let link = dir + "/ld-link.so.2"
  @fs.symlink(link, target=loader)
  assert_true(@fs.kind(link) is Regular)
  assert_true(elf_file_usable(link, 62))
  // A truncated prefix of the same file is still refused.
  let short = dir + "/ld-short.so.2"
  let whole = make_test_elf64(62, 3, None, [], None, [], [])
  @fs.write_file(short, whole[:20].to_owned())
  assert_true(!elf_file_usable(short, 62))
}
