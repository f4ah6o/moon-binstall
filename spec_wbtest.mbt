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
  let payload =
    "{\"tag_name\":\"v1.0\",\"assets\":[{\"name\":\"turtles-linux-x86_64\",\"browser_download_url\":\"https://github.com/gpui-mbt/turtles.mbt/releases/download/v1.0/turtles-linux-x86_64\",\"digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}]}"
  let asset = resolve_release(payload, t, "linux-x86_64")
  assert_eq(asset.name, "turtles-linux-x86_64")
  assert_eq(asset.tag, "v1.0")
}

///|
test "parse options" {
  let config = parse_options(["install", "dsh", "--bin-dir", "/tmp/bin", "--dry-run"])
  assert_eq(config.pkg.binary, "dsh")
  assert_eq(config.directory, Some("/tmp/bin"))
  assert_eq(config.dry_run, true)
  assert_eq(config.force, false)
}
