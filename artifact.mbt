///|
/// One package's published binary artifact settings from moon-binstall.json.
pub struct ArtifactConfig {
  package_path : String
  binary : String
  pkg_url : String?
  pkg_fmt : String?
  bin_path : String?
}

///|
/// Parse the optional package settings from a module-root moon-binstall.json.
/// The file is part of the Mooncakes source archive, whose independent source
/// checksum is verified before this parser is called.
pub fn parse_artifact_config(
  payload : String,
  package_path : String,
  default_binary : String,
) -> ArtifactConfig? raise {
  let document = @json.parse(payload)
  guard document is { "packages": Array(entries), .. } else {
    fail("invalid moon-binstall.json: expected a packages array")
  }
  let mut found : ArtifactConfig? = None
  for entry in entries {
    match entry {
      { "package": String(name), .. } if name == package_path => {
        if found is Some(_) {
          fail("duplicate package entry: \{package_path}")
        }
        let binary = match entry {
          { "binary": String(value), .. } => value
          _ => default_binary
        }
        let pkg_url = match entry {
          { "pkg-url": String(value), .. } => Some(value)
          _ => None
        }
        let pkg_fmt = match entry {
          { "pkg-fmt": String(value), .. } => Some(value)
          _ => None
        }
        let bin_path = match entry {
          { "bin-path": String(value), .. } => Some(value)
          _ => None
        }
        guard safe_binary_name(binary) else {
          fail("unsafe binary name in moon-binstall.json")
        }
        match pkg_fmt {
          Some(format) => validate_archive_format(format)
          None => ()
        }
        match pkg_url {
          Some(template) => {
            guard template != "" else {
              fail("empty pkg-url in moon-binstall.json")
            }
          }
          None => ()
        }
        match bin_path {
          Some(path) => validate_member_path(path)
          None => ()
        }
        found = Some({ package_path, binary, pkg_url, pkg_fmt, bin_path, })
      }
      _ => ()
    }
  }
  found
}

///|
/// Read the source repository from a local test/maintainer manifest. If it is
/// omitted, owner/module is used as the GitHub repository coordinate.
pub fn manifest_repository(
  payload : String,
  module_path : String,
) -> String raise {
  let document = @json.parse(payload)
  let repository = match document {
    { "repository": String(value), .. } => value
    _ => {
      let parts = module_path.split("/").collect()
      guard parts.length() == 2 &&
        valid_id(parts[0].to_owned()) &&
        valid_id(parts[1].to_owned()) else {
        fail("manifest needs a valid repository")
      }
      "https://github.com/\{parts[0]}/\{parts[1]}"
    }
  }
  let (owner, repo) = parse_github_repository(repository)
  "https://github.com/\{owner}/\{repo}"
}

///|
pub fn manifest_version(payload : String) -> String? raise {
  let document = @json.parse(payload)
  match document {
    { "version": String(value), .. } => {
      guard valid_registry_version(value) else {
        fail("unsafe version in moon-binstall.json")
      }
      Some(value)
    }
    _ => None
  }
}

///|
pub fn expand_artifact_template(
  template : String,
  owner : String,
  repo : String,
  module_name : String,
  package_path : String,
  binary : String,
  version : String,
  target : String,
  archive_suffix : String,
) -> String raise {
  let values : Array[(String, String)] = [
    ("{repo}", "https://github.com/\{owner}/\{repo}"),
    ("{name}", module_name),
    ("{module}", module_name),
    ("{package}", package_path),
    ("{bin}", binary),
    ("{binary}", binary),
    ("{version}", version),
    ("{target}", target),
    ("{archive-suffix}", archive_suffix),
    (
      "{archive-format}",
      if archive_suffix.has_prefix(".") {
        archive_suffix[1:].to_owned()
      } else {
        archive_suffix
      },
    ),
  ]
  let mut result = template
  for (key, value) in values {
    result = result.split(key).collect().join(value)
  }
  guard !result.contains("{") && !result.contains("}") else {
    fail("unsupported variable in artifact template")
  }
  result
}

///|
pub fn artifact_url_asset_name(
  url : String,
  owner : String,
  repo : String,
  tag : String,
) -> String raise {
  let prefix = "https://github.com/\{owner}/\{repo}/releases/download/\{tag}/"
  guard url.has_prefix(prefix) else {
    fail(
      "pkg-url must resolve to a GitHub release asset in the module repository",
    )
  }
  let name = url[prefix.length():].to_owned()
  guard valid_asset_name(name) else {
    fail("unsafe release asset name in pkg-url")
  }
  name
}

///|
pub fn infer_archive_format(name : String) -> String {
  if name.has_suffix(".tar.gz") {
    "tar.gz"
  } else if name.has_suffix(".tgz") {
    "tgz"
  } else if name.has_suffix(".zip") {
    "zip"
  } else {
    "bin"
  }
}

///|
pub fn archive_suffix(format : String) -> String raise {
  validate_archive_format(format)
  match format {
    "bin" => ""
    "tgz" => ".tgz"
    "tar.gz" => ".tar.gz"
    "zip" => ".zip"
    _ => fail("unsupported archive format")
  }
}

///|
pub fn validate_archive_format(format : String) -> Unit raise {
  guard format == "bin" ||
    format == "tgz" ||
    format == "tar.gz" ||
    format == "zip" else {
    fail(
      "unsupported package format: \{format} (supported: bin, tgz, tar.gz, zip)",
    )
  }
}

///|
pub fn safe_binary_name(name : String) -> Bool {
  if name == "" || name == "." || name == ".." || name.has_prefix("-") {
    return false
  }
  for c in name {
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
/// Reject absolute paths, traversal, option-like member names, backslashes,
/// and control characters before a member path is passed to an archive tool.
pub fn validate_member_path(path : String) -> Unit raise {
  guard path != "" &&
    !path.has_prefix("/") &&
    !path.has_prefix("-") &&
    !path.contains("\\") else {
    fail("unsafe archive member path")
  }
  let parts = path.split("/").collect()
  for part in parts {
    guard part != "" && part != "." && part != ".." else {
      fail("unsafe archive member path")
    }
    for c in part {
      guard c != '\n' && c != '\r' && c != '\t' else {
        fail("unsafe archive member path")
      }
    }
  }
}

///|
pub fn default_artifact_names(
  binary : String,
  version : String,
  target : String,
) -> Array[String] {
  let names : Array[String] = []
  let versions = [version, "v" + version]
  let formats = ["", ".tar.gz", ".tgz", ".zip"]
  for format in formats {
    names.push("\{binary}-\{target}\{format}")
    for version_part in versions {
      names.push("\{binary}-\{target}-\{version_part}\{format}")
      names.push("\{binary}-\{version_part}-\{target}\{format}")
    }
  }
  names
}

///|
/// When the caller selects an archive format, do not let an earlier raw
/// candidate shadow the matching archive asset in the release.
pub fn default_artifact_names_for_format(
  binary : String,
  version : String,
  target : String,
  format : String?,
) -> Array[String] raise {
  match format {
    None => default_artifact_names(binary, version, target)
    Some(selected) => {
      let suffix = archive_suffix(selected)
      let names : Array[String] = []
      let versions = [version, "v" + version]
      names.push("\{binary}-\{target}\{suffix}")
      for version_part in versions {
        names.push("\{binary}-\{target}-\{version_part}\{suffix}")
        names.push("\{binary}-\{version_part}-\{target}\{suffix}")
      }
      names
    }
  }
}
