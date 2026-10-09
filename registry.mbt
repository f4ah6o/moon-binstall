///|
/// Exact-version Mooncakes metadata used to resolve the source repository.
/// `checksum` authenticates the Mooncakes source archive only.
pub struct RegistryRelease {
  module_path : String
  version : String
  repository : String
  checksum : String
}

///|
pub fn mooncakes_manifest_url(
  module_path : String,
  version : String?,
) -> String raise {
  let parts = module_path.split("/").collect()
  guard parts.length() == 2 &&
    valid_id(parts[0].to_owned()) &&
    valid_id(parts[1].to_owned()) else {
    fail("Mooncakes module must be owner/module")
  }
  let version_suffix = match version {
    Some(v) => {
      guard valid_registry_version(v) else { fail("unsafe Mooncakes version") }
      "@" + v
    }
    None => ""
  }
  "https://mooncakes.io/api/v0/manifest/\{parts[0]}/\{parts[1]}\{version_suffix}"
}

///|
pub fn mooncakes_source_url(
  module_path : String,
  version : String,
) -> String raise {
  let parts = module_path.split("/").collect()
  guard parts.length() == 2 &&
    valid_id(parts[0].to_owned()) &&
    valid_id(parts[1].to_owned()) &&
    valid_registry_version(version) else {
    fail("unsafe Mooncakes source coordinate")
  }
  "https://download.mooncakes.io/user/\{parts[0]}/\{parts[1]}/\{version}.zip"
}

///|
/// Parse the response from the Mooncakes exact-release manifest endpoint.
/// The response's repository and source checksum are never treated as binary
/// artifact metadata.
pub fn resolve_registry_release(
  payload : String,
  expected_module : String,
  expected_version : String?,
) -> RegistryRelease raise {
  let document = @json.parse(payload)
  guard document
    is {
      "module": String(actual_module),
      "version": String(version),
      "metadata": {
        "repository": String(repository),
        "checksum": String(checksum),
        ..
      },
      ..
    } else {
    fail("invalid Mooncakes registry response")
  }
  guard actual_module == expected_module else {
    fail("Mooncakes returned a different module: \{actual_module}")
  }
  guard valid_registry_version(version) else {
    fail("Mooncakes returned an unsafe release version")
  }
  if expected_version is Some(expected) && version != expected {
    fail("Mooncakes returned version \{version}, expected \{expected}")
  }
  if document is { "yanked": true, .. } {
    fail("Mooncakes release is yanked: \{actual_module}@\{version}")
  }
  guard valid_sha256_hex(checksum) else {
    fail("Mooncakes release has no valid source checksum")
  }
  let (owner, repo) = parse_github_repository(repository)
  {
    module_path: actual_module,
    version,
    repository: "https://github.com/\{owner}/\{repo}",
    checksum,
  }
}

///|
pub fn parse_github_repository(repository : String) -> (String, String) raise {
  let prefix = "https://github.com/"
  guard repository.has_prefix(prefix) else {
    fail("Mooncakes repository must be an HTTPS GitHub URL")
  }
  let suffix = repository[prefix.length():].to_owned()
  guard !suffix.has_suffix("/") &&
    !suffix.has_prefix("/") &&
    !suffix.contains("?") &&
    !suffix.contains("#") else {
    fail("unsafe GitHub repository URL")
  }
  let path = if suffix.has_suffix(".git") {
    suffix[:suffix.length() - 4].to_owned()
  } else {
    suffix
  }
  let parts = path.split("/").collect()
  guard parts.length() == 2 &&
    valid_id(parts[0].to_owned()) &&
    valid_id(parts[1].to_owned()) else {
    fail("unsafe GitHub repository URL")
  }
  (parts[0].to_owned(), parts[1].to_owned())
}

///|
pub fn valid_sha256_hex(value : String) -> Bool {
  if value.length() != 64 {
    return false
  }
  for c in value {
    if !((c >= '0' && c <= '9') ||
      (c >= 'a' && c <= 'f') ||
      (c >= 'A' && c <= 'F')) {
      return false
    }
  }
  true
}

///|
pub async fn verify_sha256_hex(path : String, expected : String) -> Unit {
  guard valid_sha256_hex(expected) else { fail("invalid SHA-256 checksum") }
  let actual = @crypto.bytes_to_hex_string(
    @crypto.sha256(@fs.read_file(path).binary()),
  )
  guard actual == expected.to_lower() else {
    fail("SHA-256 verification failed: expected \{expected}, got \{actual}")
  }
}
