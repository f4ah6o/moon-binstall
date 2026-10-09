///|
/// Only explicit GitHub repository coordinates are accepted.
/// No shell invocation is constructed from these values.
pub struct Package {
  owner : String
  repo : String
  binary : String
  version : String?
}

///|
/// A Mooncakes package coordinate within a versioned module.
pub struct MooncakesPackage {
  module_path : String
  package_path : String
  binary : String
  version : String?
}

///|
/// A source coordinate accepted by the installer.
pub enum InstallCoordinate {
  GitHub(Package)
  Mooncakes(MooncakesPackage)
}

///|
pub fn parse_package(input : String) -> Package raise {
  let parts = input.split("@").collect()
  guard parts.length() >= 1 && parts.length() <= 2 else {
    fail("expected owner/repo[@tag]")
  }
  let coordinate = parts[0].to_owned()
  let version = if parts.length() == 2 {
    guard valid_tag(parts[1].to_owned()) else { fail("unsafe or empty tag") }
    Some(parts[1].to_owned())
  } else {
    None
  }
  let path = coordinate.split("/").collect()
  guard path.length() == 2 else { fail("expected owner/repo[@tag]") }
  guard valid_id(path[0].to_owned()) && valid_id(path[1].to_owned()) else {
    fail("unsafe GitHub repository coordinate")
  }
  let name = path[1].to_owned()
  let binary = if name.has_suffix(".mbt") {
    name[:name.length() - 4].to_owned()
  } else {
    name
  }
  guard binary != "" else { fail("repository name has an empty binary name") }
  let resolved = (path[0].to_owned(), path[1].to_owned(), binary)
  { owner: resolved.0, repo: resolved.1, binary: resolved.2, version, }
}

///| Parse either the compatible GitHub coordinate or a Mooncakes package path.

///| `owner/module/package` is a Mooncakes coordinate; two path segments remain

///|
/// GitHub `owner/repository` for backwards compatibility.
pub fn parse_coordinate(input : String) -> InstallCoordinate raise {
  let parts = input.split("@").collect()
  guard parts.length() >= 1 && parts.length() <= 2 else {
    fail("expected owner/repo[@tag] or owner/module/package[@version]")
  }
  let coordinate = parts[0].to_owned()
  let path = coordinate.split("/").collect()
  if path.length() < 3 {
    return GitHub(parse_package(input))
  }
  let version = if parts.length() == 2 {
    guard valid_registry_version(parts[1].to_owned()) else {
      fail("unsafe or empty version")
    }
    Some(parts[1].to_owned())
  } else {
    None
  }
  guard valid_id(path[0].to_owned()) && valid_id(path[1].to_owned()) else {
    fail("unsafe Mooncakes module coordinate")
  }
  let mut package_path = ""
  for i = 2; i < path.length(); i = i + 1 {
    guard valid_id(path[i].to_owned()) else {
      fail("unsafe Mooncakes package path")
    }
    if package_path != "" {
      package_path = package_path + "/"
    }
    package_path = package_path + path[i].to_owned()
  }
  let binary = binary_from_package_path(package_path)
  guard binary != "" else { fail("package path has an empty binary name") }
  Mooncakes({
    module_path: path[0].to_owned() + "/" + path[1].to_owned(),
    package_path,
    binary,
    version,
  })
}

///|
/// Parse a package path when the module is supplied separately with --module.
pub fn parse_module_package(
  module_path : String,
  input : String,
) -> MooncakesPackage raise {
  let parts = input.split("@").collect()
  guard parts.length() >= 1 && parts.length() <= 2 else {
    fail("expected package/path[@version]")
  }
  let module_parts = module_path.split("/").collect()
  guard module_parts.length() == 2 &&
    valid_id(module_parts[0].to_owned()) &&
    valid_id(module_parts[1].to_owned()) else {
    fail("--module must be owner/module")
  }
  let version = if parts.length() == 2 {
    guard valid_registry_version(parts[1].to_owned()) else {
      fail("unsafe or empty version")
    }
    Some(parts[1].to_owned())
  } else {
    None
  }
  let package_parts = parts[0].to_owned().split("/").collect()
  guard package_parts.length() > 0 else { fail("missing package path") }
  for part in package_parts {
    guard valid_id(part.to_owned()) else {
      fail("unsafe Mooncakes package path")
    }
  }
  let package_path = parts[0].to_owned()
  let binary = binary_from_package_path(package_path)
  guard binary != "" else { fail("package path has an empty binary name") }
  MooncakesPackage::{ module_path, package_path, binary, version, }
}

///|
fn binary_from_package_path(package_path : String) -> String {
  let parts = package_path.split("/").collect()
  let leaf = parts[parts.length() - 1].to_owned()
  if leaf.has_suffix(".mbt") {
    leaf[:leaf.length() - 4].to_owned()
  } else {
    leaf
  }
}

///|
fn valid_registry_version(value : String) -> Bool {
  if value == "" || value.has_prefix(".") || value.has_suffix(".") {
    return false
  }
  for c in value {
    if !((c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '-' ||
      c == '.' ||
      c == '+') {
      return false
    }
  }
  true
}

///|
fn valid_id(value : String) -> Bool {
  if value == "" || value == "." || value == ".." {
    return false
  }
  for c in value {
    if !((c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '-' ||
      c == '_' ||
      c == '.') {
      return false
    }
  }
  true
}

///|
fn valid_tag(value : String) -> Bool {
  if value == "" || value == "." || value == ".." || value.has_prefix(".") {
    return false
  }
  for c in value {
    if !((c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '-' ||
      c == '_' ||
      c == '.' ||
      c == '+') {
      return false
    }
  }
  true
}

///|
pub fn release_url(pkg : Package) -> String {
  let root = "https://api.github.com/repos/\{pkg.owner}/\{pkg.repo}/releases"
  match pkg.version {
    Some(tag) => root + "/tags/" + tag
    None => root + "/latest"
  }
}

///|
/// GitHub Releases assets have a stable, archive-free format. Unrecognized
/// systems fail closed instead of downloading a binary for another CPU.
pub fn platform_key(os : String, cpu : String) -> String raise {
  let system = match os {
    "Linux" => "linux"
    "Darwin" => "darwin"
    _ => fail("unsupported OS: \{os} (Linux/macOS only)")
  }
  let arch = match cpu {
    "x86_64" | "amd64" => "x86_64"
    "arm64" | "aarch64" => "aarch64"
    _ => fail("unsupported CPU: \{cpu}")
  }
  "\{system}-\{arch}"
}

///|
pub fn expected_asset(pkg : Package, target : String) -> String {
  "\{pkg.binary}-\{target}"
}

///|
pub struct ReleaseAsset {
  url : String
  digest : String
  name : String
  tag : String
}

///|
/// A release without a GitHub SHA-256 digest is not safe to install.
/// The URL is also pinned to the requested repository's release namespace.
pub fn resolve_release(
  payload : String,
  pkg : Package,
  target : String,
) -> ReleaseAsset raise {
  resolve_release_names(
    payload,
    pkg.owner,
    pkg.repo,
    [expected_asset(pkg, target)],
    pkg.version,
  )
}

///|
/// Resolve an asset by name and bind its URL to the API's exact release path.
pub fn resolve_release_names(
  payload : String,
  owner : String,
  repo : String,
  expected_names : Array[String],
  expected_tag : String?,
) -> ReleaseAsset raise {
  match
    resolve_release_names_optional(
      payload, owner, repo, expected_names, expected_tag,
    ) {
    Some(asset) => asset
    None => fail("no matching prebuilt asset in release")
  }
}

///|
/// Resolve the first present candidate, returning None only when none of the
/// expected names exists. A matching but malformed entry is always an error.
pub fn resolve_release_names_optional(
  payload : String,
  owner : String,
  repo : String,
  expected_names : Array[String],
  expected_tag : String?,
) -> ReleaseAsset? raise {
  let document = @json.parse(payload)
  guard document is { "tag_name": String(tag), "assets": Array(assets), .. } else {
    fail("invalid GitHub release response")
  }
  guard expected_names.length() > 0 else { fail("no expected release assets") }
  match expected_tag {
    Some(expected) =>
      if tag != expected {
        fail("GitHub returned tag \{tag}, expected \{expected}")
      }
    None => ()
  }
  let origin = "https://github.com/\{owner}/\{repo}/releases/download/\{tag}/"
  for expected in expected_names {
    guard valid_asset_name(expected) else {
      fail("unsafe expected release asset name")
    }
    let mut matched : ReleaseAsset? = None
    for entry in assets {
      match entry {
        { "name": String(name), .. } if name == expected => {
          if matched is Some(_) {
            fail("duplicate release asset name: \{name}")
          }
          let (url, digest) = match entry {
            {
              "browser_download_url": String(url),
              "digest": String(digest),
              ..
            } => (url, digest)
            _ => fail("release asset metadata is incomplete: \{name}")
          }
          guard valid_github_digest(digest) else {
            fail("release asset has no valid SHA-256 digest")
          }
          guard url == origin + expected else {
            fail("release asset URL is not in the requested repository")
          }
          matched = Some({
            url,
            digest: "sha256:" + digest[7:].to_owned(),
            name,
            tag,
          })
        }
        _ => ()
      }
    }
    if matched is Some(asset) {
      return Some(asset)
    }
  }
  None
}

///|
fn valid_asset_name(name : String) -> Bool {
  if name == "" || name == "." || name == ".." || name.has_prefix("-") {
    return false
  }
  for c in name {
    if !((c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '-' ||
      c == '_' ||
      c == '.' ||
      c == '+') {
      return false
    }
  }
  true
}

///|
fn valid_github_digest(value : String) -> Bool {
  value.has_prefix("sha256:") && valid_sha256_hex(value[7:].to_owned())
}
