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
    abort_install(
      Coordinate, "build Mooncakes manifest URL", module_path,
      "a Mooncakes module must be owner/module",
    )
  }
  let version_suffix = match version {
    Some(v) => {
      guard valid_registry_version(v) else {
        abort_install(
          Coordinate, "build Mooncakes manifest URL", v,
          "the Mooncakes version is unsafe",
        )
      }
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
    abort_install(
      Coordinate, "build Mooncakes source URL", module_path,
      "unsafe Mooncakes source coordinate",
    )
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
    abort_install(
      Resolve, "read Mooncakes metadata", expected_module,
      "the Mooncakes registry response was not valid metadata",
      action="retry; if it persists the registry response may be malformed",
    )
  }
  guard actual_module == expected_module else {
    abort_install(
      Resolve, "read Mooncakes metadata", expected_module,
      "Mooncakes returned a different module: \{actual_module}",
    )
  }
  guard valid_registry_version(version) else {
    abort_install(
      Resolve, "read Mooncakes metadata", expected_module,
      "Mooncakes returned an unsafe release version",
    )
  }
  if expected_version is Some(expected) && version != expected {
    abort_install(
      Resolve, "read Mooncakes metadata", expected_module,
      "Mooncakes returned version \{version}, expected \{expected}",
    )
  }
  if document is { "yanked": true, .. } {
    abort_install(
      Resolve, "read Mooncakes metadata", expected_module,
      "the Mooncakes release is yanked: \{actual_module}@\{version}",
      action="choose a different version or package",
    )
  }
  guard valid_sha256_hex(checksum) else {
    abort_install(
      Resolve, "read Mooncakes metadata", expected_module,
      "the Mooncakes release has no valid source checksum",
    )
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
    abort_install(
      Resolve, "read Mooncakes metadata", repository,
      "the Mooncakes repository must be an HTTPS GitHub URL",
    )
  }
  let suffix = repository[prefix.length():].to_owned()
  guard !suffix.has_suffix("/") &&
    !suffix.has_prefix("/") &&
    !suffix.contains("?") &&
    !suffix.contains("#") else {
    abort_install(
      Resolve, "read Mooncakes metadata", repository,
      "the GitHub repository URL is unsafe",
    )
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
    abort_install(
      Resolve, "read Mooncakes metadata", repository,
      "the GitHub repository URL is unsafe",
    )
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
  guard valid_sha256_hex(expected) else {
    abort_install(
      Digest, "verify checksum", path, "the expected checksum is not valid SHA-256",
    )
  }
  let actual = @crypto.bytes_to_hex_string(
    @crypto.sha256(@fs.read_file(path).binary()),
  )
  guard actual == expected.to_lower() else {
    abort_install(
      Digest, "verify checksum", path,
      "SHA-256 verification failed: expected \{expected}, got \{actual}",
      action="nothing was installed; the fetched content did not match the declared checksum",
    )
  }
}
