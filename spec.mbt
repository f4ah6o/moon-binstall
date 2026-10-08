///|
/// Only explicit GitHub coordinates and the three owned aliases are accepted.
/// No shell invocation is constructed from these values.
pub struct Package {
  pub owner : String
  pub repo : String
  pub binary : String
  pub version : String?
} derive(Eq, Show)

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
  let resolved = match coordinate {
    "turtles" | "turtles.mbt" | "gpui-mbt/turtles.mbt" =>
      ("gpui-mbt", "turtles.mbt", "turtles")
    "hotpath" | "hotpath.mbt" | "gpui-mbt/hotpath.mbt" =>
      ("gpui-mbt", "hotpath.mbt", "hotpath-report")
    "dsh" | "dsh.mbt" | "f4ah6o/dsh.mbt" =>
      ("f4ah6o", "dsh.mbt", "dsh")
    other => {
      let path = other.split("/").collect()
      guard path.length() == 2 else {
        fail("expected owner/repo[@tag]; aliases: turtles, hotpath, dsh")
      }
      guard valid_id(path[0].to_owned()) && valid_id(path[1].to_owned()) else {
        fail("unsafe GitHub repository coordinate")
      }
      // Outside the aliases, a repo whose name ends with .mbt is treated
      // as a generic CLI named after the repo without the .mbt suffix.
      let name = path[1].to_owned()
      let binary = if name.has_suffix(".mbt") {
        name.substring(end=name.length() - 4)
      } else {
        name
      }
      (path[0].to_owned(), path[1].to_owned(), binary)
    }
  }
  { owner: resolved.0, repo: resolved.1, binary: resolved.2, version }
}

///|
fn valid_id(value : String) -> Bool {
  if value == "" || value == "." || value == ".." { return false }
  for c in value {
    if !((c >= 'a' && c <= 'z') ||
         (c >= 'A' && c <= 'Z') ||
         (c >= '0' && c <= '9') ||
         c == '-' || c == '_' || c == '.') {
      return false
    }
  }
  true
}

///|
fn valid_tag(value : String) -> Bool {
  valid_id(value) && !value.has_prefix(".")
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
  pub url : String
  pub digest : String
  pub name : String
  pub tag : String
} derive(Eq, Show)

///|
/// A release without a GitHub SHA-256 digest is not safe to install.
/// The URL is also pinned to the requested repository's release namespace.
pub fn resolve_release(
  payload : String,
  pkg : Package,
  target : String,
) -> ReleaseAsset raise {
  let document = @json.parse(payload)
  guard document is {
    "tag_name": String(tag),
    "assets": Array(assets),
    ..
  } else {
    fail("invalid GitHub release response")
  }
  let expected = expected_asset(pkg, target)
  for entry in assets {
    match entry {
      {
        "name": String(name),
        "browser_download_url": String(url),
        "digest": String(digest),
        ..
      } => {
        if name != expected { continue }
        let origin = "https://github.com/\{pkg.owner}/\{pkg.repo}/releases/download/"
        guard url.has_prefix(origin) && url.ends_with("/" + expected) else {
          fail("release asset URL is not in the requested repository")
        }
        guard digest.has_prefix("sha256:") && digest.length() == 71 else {
          fail("release asset has no valid SHA-256 digest")
        }
        return { url, digest, name, tag }
      }
      _ => ()
    }
  }
  fail("no prebuilt \{expected} asset in release \{tag}")
}
