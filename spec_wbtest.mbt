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
