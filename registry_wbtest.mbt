///|
async test "Mooncakes metadata supports latest and exact release shapes" {
  assert_eq(
    mooncakes_manifest_url("f4ah6o/moon-binstall", None),
    "https://mooncakes.io/api/v0/manifest/f4ah6o/moon-binstall",
  )
  assert_eq(
    mooncakes_manifest_url("f4ah6o/moon-binstall", Some("0.1.2")),
    "https://mooncakes.io/api/v0/manifest/f4ah6o/moon-binstall@0.1.2",
  )
  assert_eq(
    mooncakes_source_url("f4ah6o/moon-binstall", "0.1.2"),
    "https://download.mooncakes.io/user/f4ah6o/moon-binstall/0.1.2.zip",
  )
  let checksum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let payload = "{\"module\":\"f4ah6o/moon-binstall\",\"version\":\"0.1.2\",\"yanked\":false,\"metadata\":{\"repository\":\"https://github.com/f4ah6o/moon-binstall\",\"checksum\":\"\{checksum}\"}}"
  let exact = resolve_registry_release(
    payload,
    "f4ah6o/moon-binstall",
    Some("0.1.2"),
  )
  assert_eq(exact.version, "0.1.2")
  assert_eq(exact.repository, "https://github.com/f4ah6o/moon-binstall")
  let latest = resolve_registry_release(payload, "f4ah6o/moon-binstall", None)
  assert_eq(latest.version, "0.1.2")
  assert_true(
    try {
      ignore(
        resolve_registry_release(payload, "f4ah6o/moon-binstall", Some("0.1.3")),
      )
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(resolve_registry_release(payload, "someone/else", Some("0.1.2")))
      false
    } catch {
      _ => true
    },
  )
}

///|
async test "Mooncakes yanked releases and invalid source checksums are rejected" {
  let checksum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let yanked = "{\"module\":\"acme/tool\",\"version\":\"1.0.0\",\"yanked\":true,\"metadata\":{\"repository\":\"https://github.com/acme/tool\",\"checksum\":\"\{checksum}\"}}"
  assert_true(
    try {
      ignore(resolve_registry_release(yanked, "acme/tool", Some("1.0.0")))
      false
    } catch {
      _ => true
    },
  )
  let bad_checksum = "{\"module\":\"acme/tool\",\"version\":\"1.0.0\",\"metadata\":{\"repository\":\"https://github.com/acme/tool\",\"checksum\":\"not-a-sha256\"}}"
  assert_true(
    try {
      ignore(resolve_registry_release(bad_checksum, "acme/tool", Some("1.0.0")))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(parse_github_repository("http://github.com/acme/tool"))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(parse_github_repository("https://github.com/acme/tool/other"))
      false
    } catch {
      _ => true
    },
  )
}

///|
async test "Mooncakes source archives are checked against their own checksum" {
  let root = @fs.tmpdir(prefix="moon-binstall-source-checksum")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let source_zip = root + "/module.zip"
  create_fixture_zip(source_zip, "moon-binstall.json", "{}")
  let checksum = fixture_digest(source_zip)
  verify_sha256_hex(source_zip, checksum[7:].to_owned())
  assert_true(
    try {
      verify_sha256_hex(
        source_zip, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      )
      false
    } catch {
      _ => true
    },
  )
}
