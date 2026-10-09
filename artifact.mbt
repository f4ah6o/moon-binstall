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
/// Parsed package metadata with exact-target overrides kept separate from the
/// stable public ArtifactConfig shape.
priv struct ArtifactConfigSet {
  base : ArtifactConfig
  overrides : Array[(String, ArtifactOverride)]
}

///|
priv struct ArtifactOverride {
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
  match parse_artifact_config_set(payload, package_path, default_binary) {
    Some(config) => Some(config.base)
    None => None
  }
}

///|
/// Parse one package's base settings and validate all of its exact-target
/// overrides before target selection begins.
fn parse_artifact_config_set(
  payload : String,
  package_path : String,
  default_binary : String,
) -> ArtifactConfigSet? raise {
  let document = @json.parse(payload)
  let entries = match document {
    { "packages": Array(values), .. } => values
    _ => fail("invalid moon-binstall.json: expected a packages array")
  }
  let mut found : ArtifactConfigSet? = None
  for entry in entries {
    let fields = match entry {
      Object(value) => value
      _ => fail("invalid package entry in moon-binstall.json")
    }
    let name = match fields.get("package") {
      Some(String(value)) => value
      _ => fail("invalid package entry in moon-binstall.json: missing package")
    }
    guard valid_package_path(name) else {
      fail("unsafe package path in moon-binstall.json")
    }
    if name == package_path {
      if found is Some(_) {
        fail("duplicate package entry: \{package_path}")
      }
      validate_metadata_keys(
        fields,
        ["package", "binary", "pkg-url", "pkg-fmt", "bin-path", "overrides"],
        "package entry",
      )
      let binary = match optional_string_field(fields, "binary") {
        Some(value) => value
        None => default_binary
      }
      let pkg_url = optional_string_field(fields, "pkg-url")
      let pkg_fmt = optional_string_field(fields, "pkg-fmt")
      let bin_path = optional_string_field(fields, "bin-path")
      validate_config_fields(pkg_url, pkg_fmt, bin_path)
      guard safe_binary_name(binary) else {
        fail("unsafe binary name in moon-binstall.json")
      }
      let overrides = parse_target_overrides(fields.get("overrides"))
      found = Some({
        base: { package_path, binary, pkg_url, pkg_fmt, bin_path, },
        overrides,
      })
    }
  }
  found
}

///|
fn optional_string_field(
  fields : Map[String, Json],
  key : String,
) -> String? raise {
  match fields.get(key) {
    None => None
    Some(String(value)) => Some(value)
    Some(_) => fail("invalid \{key} in moon-binstall.json: expected a string")
  }
}

///|
fn parse_target_overrides(
  value : Json?,
) -> Array[(String, ArtifactOverride)] raise {
  let overrides : Array[(String, ArtifactOverride)] = []
  match value {
    None => ()
    Some(Object(targets)) =>
      for (target, raw_config) in targets.iter() {
        validate_target(target)
        let fields = match raw_config {
          Object(value) => value
          _ => fail("invalid override for target \{target}: expected an object")
        }
        validate_metadata_keys(
          fields,
          ["pkg-url", "pkg-fmt", "bin-path"],
          "target override",
        )
        let pkg_url = optional_string_field(fields, "pkg-url")
        let pkg_fmt = optional_string_field(fields, "pkg-fmt")
        let bin_path = optional_string_field(fields, "bin-path")
        guard pkg_url is Some(_) || pkg_fmt is Some(_) || bin_path is Some(_) else {
          fail("empty override for target \{target}")
        }
        validate_config_fields(pkg_url, pkg_fmt, bin_path)
        overrides.push((target, { pkg_url, pkg_fmt, bin_path, }))
      }
    Some(_) => fail("invalid overrides in moon-binstall.json: expected an object")
  }
  overrides
}

///|
fn validate_metadata_keys(
  fields : Map[String, Json],
  allowed : Array[String],
  context : String,
) -> Unit raise {
  for (key, _) in fields.iter() {
    guard allowed.contains(key) else {
      fail("unsupported field in moon-binstall.json \{context}: \{key}")
    }
  }
}

///|
fn valid_package_path(path : String) -> Bool {
  let parts = path.split("/").collect()
  if parts.length() == 0 {
    return false
  }
  for part in parts {
    if !valid_id(part.to_owned()) {
      return false
    }
  }
  true
}

///|
fn validate_config_fields(
  pkg_url : String?,
  pkg_fmt : String?,
  bin_path : String?,
) -> Unit raise {
  match pkg_fmt {
    Some(format) => validate_archive_format(format)
    None => ()
  }
  match pkg_url {
    Some(template) => {
      guard template != "" else { fail("empty pkg-url in moon-binstall.json") }
      validate_artifact_template(template)
    }
    None => ()
  }
  match bin_path {
    Some(template) => {
      validate_artifact_template(template)
      validate_member_template(template)
    }
    None => ()
  }
}

///|
fn validate_member_template(template : String) -> Unit raise {
  // Substitute path-safe values so unsafe literal traversal is rejected at
  // manifest parse time, including for a lower-priority target override.
  let expanded = expand_artifact_member_template(
    template,
    "owner",
    "repo",
    "module",
    "package/path",
    "binary",
    "1.2.3",
    "linux-x86_64",
    ".tgz",
  )
  validate_member_path(expanded)
}

///|
fn artifact_config_for_target(
  set : ArtifactConfigSet,
  target : String,
) -> ArtifactConfig {
  let mut pkg_url = set.base.pkg_url
  let mut pkg_fmt = set.base.pkg_fmt
  let mut bin_path = set.base.bin_path
  for (override_target, value) in set.overrides {
    if override_target == target {
      if value.pkg_url is Some(url) {
        pkg_url = Some(url)
      }
      if value.pkg_fmt is Some(format) {
        pkg_fmt = Some(format)
      }
      if value.bin_path is Some(path) {
        bin_path = Some(path)
      }
      break
    }
  }
  {
    package_path: set.base.package_path,
    binary: set.base.binary,
    pkg_url,
    pkg_fmt,
    bin_path,
  }
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
  expand_artifact_template_with_format_alias(
    template, owner, repo, module_name, package_path, binary, version, target,
    archive_suffix, false,
  )
}

///|
/// In a member-path template, Cargo's soft-deprecated `{format}` alias refers
/// to the executable extension (`binary-ext`), which is empty for our targets.
fn expand_artifact_member_template(
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
  expand_artifact_template_with_format_alias(
    template, owner, repo, module_name, package_path, binary, version, target,
    archive_suffix, true,
  )
}

///|
fn expand_artifact_template_with_format_alias(
  template : String,
  owner : String,
  repo : String,
  module_name : String,
  package_path : String,
  binary : String,
  version : String,
  target : String,
  archive_suffix : String,
  member_path : Bool,
) -> String raise {
  let (target_family, target_os, target_arch) = target_template_facts(target)
  let archive_format = if archive_suffix.has_prefix(".") {
    archive_suffix[1:].to_owned()
  } else {
    archive_suffix
  }
  let values : Array[(String, String)] = [
    ("repo", "https://github.com/\{owner}/\{repo}"),
    ("name", module_name),
    ("module", module_name),
    ("package", package_path),
    ("bin", binary),
    ("binary", binary),
    ("version", version),
    ("target", target),
    ("archive-suffix", archive_suffix),
    (
      "archive-format",
      archive_format,
    ),
    ("format", if member_path { "" } else { archive_format }),
    ("target-family", target_family),
    ("target-arch", target_arch),
    ("os-name", target_os),
    ("binary-ext", ""),
  ]
  expand_template(template, values)
}

///|
fn target_template_facts(target : String) -> (String, String, String) raise {
  match target {
    "linux-x86_64" => ("linux", "linux", "x86_64")
    "linux-aarch64" => ("linux", "linux", "aarch64")
    "darwin-x86_64" => ("darwin", "macos", "x86_64")
    "darwin-aarch64" => ("darwin", "macos", "aarch64")
    _ => fail("unsupported target in artifact template: \{target}")
  }
}

///|
/// Validate placeholders without needing a resolved target. This runs over
/// every declared base and target-specific template before asset fallback.
pub fn validate_artifact_template(template : String) -> Unit raise {
  let known = [
    "repo", "name", "module", "package", "bin", "binary", "version",
    "target", "archive-suffix", "archive-format", "format", "target-family",
    "target-arch", "os-name", "binary-ext",
  ]
  let chars : Array[Char] = []
  for c in template {
    chars.push(c)
  }
  let mut index = 0
  while index < chars.length() {
    let current = chars[index]
    if current == '\\' && index + 1 < chars.length() {
      let next = chars[index + 1]
      if next == '{' || next == '}' || next == '\\' {
        index = index + 2
        continue
      }
    }
    if current == '{' {
      index = index + 1
      let mut variable = ""
      while index < chars.length() && chars[index] != '}' {
        guard chars[index] != '{' else {
          fail("nested opening brace in artifact template")
        }
        variable = variable + chars[index].to_string()
        index = index + 1
      }
      guard index < chars.length() else {
        fail("unclosed variable in artifact template")
      }
      let key = variable.trim().to_owned()
      guard known.contains(key) else {
        fail("unsupported variable in artifact template: \{key}")
      }
      index = index + 1
      continue
    }
    if current == '}' {
      fail("unmatched closing brace in artifact template")
    }
    index = index + 1
  }
}

///|
fn expand_template(
  template : String,
  values : Array[(String, String)],
) -> String raise {
  let chars : Array[Char] = []
  for c in template {
    chars.push(c)
  }
  let mut result = ""
  let mut index = 0
  while index < chars.length() {
    let current = chars[index]
    if current == '\\' && index + 1 < chars.length() {
      let next = chars[index + 1]
      if next == '{' || next == '}' || next == '\\' {
        result = result + next.to_string()
        index = index + 2
        continue
      }
    }
    if current == '{' {
      index = index + 1
      let mut variable = ""
      while index < chars.length() && chars[index] != '}' {
        guard chars[index] != '{' else {
          fail("nested opening brace in artifact template")
        }
        variable = variable + chars[index].to_string()
        index = index + 1
      }
      guard index < chars.length() else {
        fail("unclosed variable in artifact template")
      }
      let key = variable.trim().to_owned()
      let mut resolved : String? = None
      for (name, value) in values {
        let candidate = if name.has_prefix("{") {
          name[1:name.length() - 1].to_owned()
        } else {
          name
        }
        if candidate == key {
          resolved = Some(value)
          break
        }
      }
      let value = match resolved {
        Some(value) => value
        None => fail("unsupported variable in artifact template: \{key}")
      }
      result = result + value
      index = index + 1
      continue
    }
    if current == '}' {
      fail("unmatched closing brace in artifact template")
    }
    result = result + current.to_string()
    index = index + 1
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
  if name.has_suffix(".tar.bz2") {
    "tar.bz2"
  } else if name.has_suffix(".tbz2") {
    "tbz2"
  } else if name.has_suffix(".tar.zstd") {
    "tar.zstd"
  } else if name.has_suffix(".tar.zst") {
    "tzstd"
  } else if name.has_suffix(".tzstd") {
    "tzstd"
  } else if name.has_suffix(".tar.xz") {
    "tar.xz"
  } else if name.has_suffix(".txz") {
    "txz"
  } else if name.has_suffix(".tar.gz") {
    "tar.gz"
  } else if name.has_suffix(".tgz") {
    "tgz"
  } else if name.has_suffix(".tar") {
    "tar"
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
    "tar" => ".tar"
    "tgz" => ".tgz"
    "tar.gz" => ".tar.gz"
    "tbz2" => ".tbz2"
    "tar.bz2" => ".tar.bz2"
    "txz" => ".txz"
    "tar.xz" => ".tar.xz"
    "tzstd" | "tar.zst" => ".tar.zst"
    "tar.zstd" => ".tar.zstd"
    "zip" => ".zip"
    _ => fail("unsupported archive format")
  }
}

///|
pub fn validate_archive_format(format : String) -> Unit raise {
  guard format == "bin" ||
    format == "tar" ||
    format == "tgz" ||
    format == "tar.gz" ||
    format == "tbz2" ||
    format == "tar.bz2" ||
    format == "txz" ||
    format == "tar.xz" ||
    format == "tzstd" ||
    format == "tar.zst" ||
    format == "tar.zstd" ||
    format == "zip" else {
    fail(
      "unsupported package format: \{format} (supported: bin, tar, tgz, tar.gz, tbz2, tar.bz2, txz, tar.xz, tzstd, tar.zst, zip)",
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
    guard part != "" && part != "." && part != ".." &&
      !part.has_prefix("-") else {
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
  let formats = [
    "", ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz",
    ".tar.zst", ".tar.zstd", ".tzstd", ".zip",
  ]
  for format in formats {
    names.push("\{binary}-\{target}\{format}")
    for version_part in versions {
      names.push("\{binary}-\{target}-\{version_part}\{format}")
      names.push("\{binary}-\{version_part}-\{target}\{format}")
    }
  }
  append_underscore_asset_names(names, binary, version, target, formats)
  names
}

///|
fn append_underscore_asset_names(
  names : Array[String],
  stem : String,
  version : String,
  target : String,
  formats : Array[String],
) -> Unit {
  let versions = [version, "v" + version]
  for format in formats {
    append_unique(names, "\{stem}_\{target}\{format}")
    for version_part in versions {
      append_unique(names, "\{stem}_\{target}_\{version_part}\{format}")
      append_unique(names, "\{stem}_\{version_part}_\{target}\{format}")
    }
  }
}

///|
fn append_unique(values : Array[String], value : String) -> Unit {
  if !values.contains(value) {
    values.push(value)
  }
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
      append_underscore_asset_names(names, binary, version, target, [suffix])
      names
    }
  }
}

///|
/// Ordered exact archive member candidates for archives that omit bin-path.
/// The existing root executable path remains first; the remaining paths use
/// the standard release-directory spellings documented by cargo-binstall.
pub fn default_archive_member_candidates(
  module_name : String,
  package_path : String,
  binary : String,
  version : String,
  target : String,
) -> Array[String] raise {
  validate_target(target)
  guard safe_binary_name(binary) && valid_id(module_name) &&
    valid_package_path(package_path) &&
    (valid_registry_version(version) || valid_tag(version)) else {
    fail("unsafe values for archive member discovery")
  }
  let candidates : Array[String] = [binary]
  let versions = [version, "v" + version]
  let directories = [
    "\{module_name}-\{target}-v\{version}",
    "\{module_name}-\{target}-\{version}",
    "\{module_name}-\{version}-\{target}",
    "\{module_name}-v\{version}-\{target}",
    "\{module_name}-\{target}",
    "\{module_name}-\{version}",
    "\{module_name}-v\{version}",
    module_name,
  ]
  for directory in directories {
    append_unique(candidates, "\{directory}/\{binary}")
  }
  // MoonBit packages are often laid out by their package path in source
  // archives. These are lower-priority exact matches after release layouts.
  append_unique(candidates, "\{package_path}/\{binary}")
  for version_part in versions {
    append_unique(candidates, "\{binary}-\{target}-\{version_part}")
    append_unique(candidates, "\{binary}-\{version_part}-\{target}")
  }
  for candidate in candidates {
    validate_member_path(candidate)
  }
  candidates
}
