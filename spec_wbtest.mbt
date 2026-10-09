///|
test "aliases and GitHub repository coordinates" {
  let t = parse_package("turtles@v1.2.3")
  assert_eq(t.owner, "gpui-mbt")
  assert_eq(t.repo, "turtles.mbt")
  assert_eq(t.binary, "turtles")
  assert_eq(t.version, Some("v1.2.3"))
  assert_eq(parse_package("gpui-mbt/hotpath.mbt").binary, "hotpath-report")
  assert_eq(parse_package("f4ah6o/dsh.mbt").binary, "dsh")
  assert_eq(parse_package("someuser/tool").binary, "tool")
  assert_true(
    try {
      ignore(parse_package("someuser/.mbt"))
      false
    } catch {
      _ => true
    },
  )
  assert_eq(
    parse_package("someuser/tool@v1.2.3+build.4").version,
    Some("v1.2.3+build.4"),
  )
  assert_eq(parse_coordinate("someuser/tool@release_tag_1") is GitHub(_), true)
}

///|
test "platform matching is explicit" {
  assert_eq(platform_key("Darwin", "arm64"), "darwin-aarch64")
  assert_eq(platform_key("Linux", "x86_64"), "linux-x86_64")
  assert_eq(platform_key("Linux", "aarch64"), "linux-aarch64")
}

///|
test "versioned API endpoint" {
  assert_eq(
    release_url(parse_package("turtles@v1.0.0")),
    "https://api.github.com/repos/gpui-mbt/turtles.mbt/releases/tags/v1.0.0",
  )
}

///|
test "release digest and repository validation" {
  let t = parse_package("turtles")
  let payload = "{\"tag_name\":\"v1.0\",\"assets\":[{\"name\":\"turtles-linux-x86_64\",\"browser_download_url\":\"https://github.com/gpui-mbt/turtles.mbt/releases/download/v1.0/turtles-linux-x86_64\",\"digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}]}"
  let asset = resolve_release(payload, t, "linux-x86_64")
  assert_eq(asset.name, "turtles-linux-x86_64")
  assert_eq(asset.tag, "v1.0")
}

///|
test "parse options" {
  let config = parse_options([
    "install", "dsh", "--bin-dir", "/tmp/bin", "--dry-run",
  ])
  assert_eq(config.pkg.binary, "dsh")
  assert_eq(config.directory, Some("/tmp/bin"))
  assert_eq(config.dry_run, true)
  assert_eq(config.force, false)
}

///|
test "batch options preserve package versions and compatibility coordinates" {
  let options = parse_batch_options([
    "--module", "acme/tools", "cmd/main", "lib/worker@1.2.3+build.4", "--target",
    "linux-x86_64", "--dry-run",
  ])
  assert_eq(options.coordinates.length(), 2)
  match options.coordinates[0] {
    Mooncakes(pkg) => {
      assert_eq(pkg.module_path, "acme/tools")
      assert_eq(pkg.package_path, "cmd/main")
      assert_eq(pkg.binary, "main")
    }
    _ => fail("--module should produce Mooncakes coordinates")
  }
  match options.coordinates[1] {
    Mooncakes(pkg) => assert_eq(pkg.version, Some("1.2.3+build.4"))
    _ => fail("--module should produce Mooncakes coordinates")
  }
  assert_true(
    try {
      ignore(
        parse_batch_options([
          "acme/tools/one", "acme/tools/two", "--version", "1.0.0",
        ]),
      )
      false
    } catch {
      _ => true
    },
  )
}

///|
test "release responses are bound to explicit requested tags" {
  let payload = "{\"tag_name\":\"v1.0.0\",\"assets\":[{\"name\":\"tool-linux-x86_64\",\"browser_download_url\":\"https://github.com/acme/tool/releases/download/v1.0.0/tool-linux-x86_64\",\"digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}]}"
  let requested = parse_package("acme/tool@v1.0.1")
  assert_true(
    try {
      ignore(resolve_release(payload, requested, "linux-x86_64"))
      false
    } catch {
      _ => true
    },
  )
  assert_eq(version_from_tag("v1.2.3"), "1.2.3")
}

///|
test "explicit package format selects matching asset when raw and zip coexist" {
  let payload = "{\"tag_name\":\"v1.0.0\",\"assets\":[{\"name\":\"tool-linux-x86_64\",\"browser_download_url\":\"https://github.com/acme/tool/releases/download/v1.0.0/tool-linux-x86_64\",\"digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"},{\"name\":\"tool-linux-x86_64.zip\",\"browser_download_url\":\"https://github.com/acme/tool/releases/download/v1.0.0/tool-linux-x86_64.zip\",\"digest\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}]}"
  let asset = resolve_release_names(
    payload,
    "acme",
    "tool",
    default_artifact_names_for_format(
      "tool",
      "1.0.0",
      "linux-x86_64",
      Some("zip"),
    ),
    Some("v1.0.0"),
  )
  assert_eq(asset.name, "tool-linux-x86_64.zip")
}

///|
test "common tar package formats and suffixes are recognized" {
  assert_eq(infer_archive_format("tool.tar"), "tar")
  assert_eq(infer_archive_format("tool.tgz"), "tgz")
  assert_eq(infer_archive_format("tool.tar.gz"), "tar.gz")
  assert_eq(infer_archive_format("tool.tbz2"), "tbz2")
  assert_eq(infer_archive_format("tool.tar.bz2"), "tar.bz2")
  assert_eq(infer_archive_format("tool.txz"), "txz")
  assert_eq(infer_archive_format("tool.tar.xz"), "tar.xz")
  assert_eq(infer_archive_format("tool.tar.zst"), "tzstd")
  assert_eq(infer_archive_format("tool.tar.zstd"), "tar.zstd")
  assert_eq(infer_archive_format("tool.zip"), "zip")
  assert_eq(archive_suffix("tzstd"), ".tar.zst")
  assert_eq(archive_suffix("tar.bz2"), ".tar.bz2")
  for format in [
    "tar", "tgz", "tar.gz", "tbz2", "tar.bz2", "txz", "tar.xz",
    "tzstd", "tar.zst", "tar.zstd",
  ] {
    validate_archive_format(format)
  }
}

///|
test "target candidates preserve order and reject ambiguous lists" {
  let options = parse_batch_options([
    "acme/tool", "--targets", "darwin-aarch64, linux-x86_64",
  ])
  assert_eq(options.target, Some("darwin-aarch64,linux-x86_64"))
  let invalid_lists = [
    "", ",linux-x86_64", "linux-x86_64,", "linux-x86_64,,darwin-aarch64",
    "linux-x86_64,linux-x86_64", "windows-x86_64",
  ]
  for value in invalid_lists {
    assert_true(
      try {
        ignore(parse_target_list(value))
        false
      } catch {
        _ => true
      },
    )
  }
  for args in [
    ["acme/tool", "--target", "linux-x86_64", "--targets", "darwin-aarch64"],
    ["acme/tool", "--targets", "darwin-aarch64", "--target", "linux-x86_64"],
  ] {
    assert_true(
      try {
        ignore(parse_batch_options(args))
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "artifact templates accept Cargo whitespace and supported target facts" {
  let expanded = expand_artifact_template(
    "{ repo }/{ target-family }/{ target-arch }/{ os-name }/{binary-ext}/\\{literal\\}",
    "acme",
    "tools",
    "toolkit",
    "cmd/cli",
    "cli",
    "1.2.3",
    "darwin-aarch64",
    ".tar.gz",
  )
  assert_eq(
    expanded,
    "https://github.com/acme/tools/darwin/aarch64/macos//{literal}",
  )
  assert_eq(
    expand_artifact_template(
      "{format}|{archive-format}|{archive-suffix}",
      "acme",
      "tools",
      "toolkit",
      "cmd/cli",
      "cli",
      "1.2.3",
      "linux-x86_64",
      ".tar.gz",
    ),
    "tar.gz|tar.gz|.tar.gz",
  )
  assert_eq(
    expand_artifact_member_template(
      "{format}|{archive-format}|{binary-ext}",
      "acme",
      "tools",
      "toolkit",
      "cmd/cli",
      "cli",
      "1.2.3",
      "linux-x86_64",
      ".zip",
    ),
    "|zip|",
  )
  assert_true(
    try {
      validate_artifact_template("{ target-libc }")
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      validate_artifact_template("{ target ")
      false
    } catch {
      _ => true
    },
  )
}

///|
test "artifact template scanners handle long literals and padded placeholders" {
  let literal_builder = StringBuilder(size_hint=65536)
  for i = 0; i < 32768; i = i + 1 {
    literal_builder.write_char('x')
  }
  let literal = literal_builder.to_string()
  let template = literal + "{ target }" + literal
  validate_artifact_template(template)
  let expanded = expand_artifact_template(
    template,
    "acme",
    "tools",
    "toolkit",
    "cmd/cli",
    "cli",
    "1.2.3",
    "linux-x86_64",
    "",
  )
  assert_true(expanded.has_prefix(literal))
  assert_true(expanded.has_suffix(literal))
  assert_eq(expanded.length(), literal.length() * 2 + "linux-x86_64".length())

  let whitespace_builder = StringBuilder(size_hint=32768)
  for i = 0; i < 16384; i = i + 1 {
    whitespace_builder.write_char(' ')
  }
  let whitespace = whitespace_builder.to_string()
  let padded_variable = "{" + whitespace + " target " + whitespace + "}"
  validate_artifact_template(padded_variable)
  assert_eq(
    expand_artifact_template(
      padded_variable,
      "acme",
      "tools",
      "toolkit",
      "cmd/cli",
      "cli",
      "1.2.3",
      "linux-x86_64",
      "",
    ),
    "linux-x86_64",
  )
}

///|
test "artifact target overrides merge fields without changing package defaults" {
  let payload = "{\"packages\":[{\"package\":\"cmd/main\",\"binary\":\"tool\",\"pkg-url\":\"{repo}/releases/download/v{version}/{bin}-{target}{archive-suffix}\",\"pkg-fmt\":\"tgz\",\"bin-path\":\"{package}/{bin}\",\"overrides\":{\"darwin-aarch64\":{\"pkg-fmt\":\"zip\",\"bin-path\":\"release/{target}/{bin}\"},\"linux-aarch64\":{\"pkg-url\":\"{ repo }/releases/download/v{ version }/{ bin }-{ target }{ archive-suffix }\",\"pkg-fmt\":\"tar.gz\"}}}]}"
  let config_set = match parse_artifact_config_set(payload, "cmd/main", "main") {
    Some(value) => value
    None => fail("expected package config")
  }
  let linux_x64 = artifact_config_for_target(config_set, "linux-x86_64")
  assert_eq(linux_x64.pkg_fmt, Some("tgz"))
  assert_eq(linux_x64.bin_path, Some("{package}/{bin}"))
  let linux_arm = artifact_config_for_target(config_set, "linux-aarch64")
  assert_eq(linux_arm.pkg_fmt, Some("tar.gz"))
  assert_eq(
    linux_arm.pkg_url,
    Some(
      "{ repo }/releases/download/v{ version }/{ bin }-{ target }{ archive-suffix }",
    ),
  )
  assert_eq(linux_arm.bin_path, Some("{package}/{bin}"))
  let darwin_arm = artifact_config_for_target(config_set, "darwin-aarch64")
  assert_eq(darwin_arm.pkg_fmt, Some("zip"))
  assert_eq(darwin_arm.bin_path, Some("release/{target}/{bin}"))
  assert_eq(
    darwin_arm.pkg_url,
    Some("{repo}/releases/download/v{version}/{bin}-{target}{archive-suffix}"),
  )
  for invalid in [
    "{\"packages\":[{\"package\":\"cmd/main\",\"overrides\":{\"windows-x86_64\":{\"pkg-fmt\":\"zip\"}}}]}",
    "{\"packages\":[{\"package\":\"cmd/main\",\"overrides\":{\"darwin-aarch64\":{\"pkg-fmt\":1}}}]}",
    "{\"packages\":[{\"package\":\"cmd/main\",\"overrides\":{\"linux-aarch64\":{\"pkg-url\":\"{unknown}\"}}}]}",
    "{\"packages\":[{\"package\":\"cmd/main\",\"overrides\":{\"darwin-aarch64\":{\"pkg_form\":\"zip\"}}}]}",
  ] {
    assert_true(
      try {
        ignore(parse_artifact_config_set(invalid, "cmd/main", "main"))
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "default artifact asset names keep current priority before underscore forms" {
  let names = default_artifact_names("tool", "1.2.3", "linux-x86_64")
  assert_eq(names[0], "tool-linux-x86_64")
  assert_true(names.contains("tool-linux-x86_64-v1.2.3.tgz"))
  assert_true(names.contains("tool_linux-x86_64_1.2.3.zip"))
  let members = default_archive_member_candidates(
    "toolkit", "cmd/main", "tool", "1.2.3", "linux-x86_64",
  )
  assert_eq(members[0], "tool")
  assert_true(members.contains("toolkit-linux-x86_64-v1.2.3/tool"))
  assert_true(members.contains("toolkit/tool"))
}
