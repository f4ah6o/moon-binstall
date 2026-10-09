///|
pub struct Options {
  pkg : Package
  directory : String?
  dry_run : Bool
  force : Bool
}

///|
/// Multi-package CLI settings. The existing Options and install entry point
/// remain available to library callers.
pub struct BatchOptions {
  coordinates : Array[InstallCoordinate]
  directory : String?
  dry_run : Bool
  force : Bool
  /// One target or an ordered comma-separated list produced by --targets.
  target : String?
  version : String?
  pkg_url : String?
  pkg_fmt : String?
  bin_path : String?
  module_path : String?
  manifest_path : String?
}

///|
pub fn usage() -> String {
  let msg =
    #|moon-binstall — install checksum-verified MoonBit CLI binaries
    #|
    #|Usage:
    #|  moon-binstall [--module OWNER/MODULE] <coordinate>... [options]
    #|  moon-binstall owner/module/package[@version]... [options]
    #|
    #|Coordinates:
    #|  owner/repo[@tag]                 GitHub Releases compatibility mode
    #|  owner/module/package[@version]   Mooncakes package metadata mode
    #|  with --module, coordinate is package/path[@version]
    #|
    #|Options:
    #|  --version VERSION     select one package version (or use @VERSION per item)
    #|  --target TARGET       override linux-x86_64, linux-aarch64, darwin-x86_64,
    #|                        or darwin-aarch64
    #|  --targets TARGETS     try comma-separated targets in the given order
    #|  --bin-dir DIR         destination directory (default $HOME/.local/bin)
    #|  --bin-path PATH       exact member inside an archive (default: discover)
    #|  --pkg-url TEMPLATE    release asset URL template
    #|  --pkg-fmt FORMAT      bin, tar, tgz, tar.gz, tbz2, tar.bz2, txz,
    #|                        tar.xz, tzstd, tar.zst, or zip
    #|  --manifest-path FILE  read local moon-binstall.json and skip registry lookup
    #|  --force               replace an existing regular executable
    #|  --dry-run             resolve without installing
    #|
    #|  moon-binstall --help
    #|  moon binstall owner/module/package[@version]... [options]
    #|  moon binstall --help
    #|
    #|Aliases: turtles, hotpath, dsh
    #|Environment: MOON_BINSTALL_DIR (default $HOME/.local/bin)
    #|
    #|Requires: curl >= 8.4.0; tar and matching codecs for tar archives;
    #|          zstd for tzstd; unzip/zipinfo for zip; macOS or Linux.
    #|Every release asset must include GitHub's SHA-256 digest.
    #|hotpath installs the optional hotpath-report example binary, not the library.
  msg
}

///|
pub fn parse_options(argv : ArrayView[String]) -> Options raise {
  let mut coordinate = ""
  let mut directory : String? = None
  let mut dry_run = false
  let mut force = false
  let mut idx = 0
  while idx < argv.length() {
    let arg = argv[idx]
    match arg {
      "install" if idx == 0 => ()
      "--dry-run" => dry_run = true
      "--force" => force = true
      "--bin-dir" => {
        idx = idx + 1
        guard idx < argv.length() && argv[idx] != "" else {
          fail("--bin-dir requires a directory")
        }
        directory = Some(argv[idx])
      }
      _ => {
        guard !arg.has_prefix("-") && coordinate == "" else {
          fail("unrecognized or duplicate argument: \{arg}")
        }
        coordinate = arg
      }
    }
    idx = idx + 1
  }
  guard coordinate != "" else { fail("missing repository coordinate") }
  { pkg: parse_package(coordinate), directory, dry_run, force, }
}

///|
pub fn parse_batch_options(argv : ArrayView[String]) -> BatchOptions raise {
  let raw_coordinates : Array[String] = []
  let mut directory : String? = None
  let mut target : String? = None
  let mut version : String? = None
  let mut pkg_url : String? = None
  let mut pkg_fmt : String? = None
  let mut bin_path : String? = None
  let mut module_path : String? = None
  let mut manifest_path : String? = None
  let mut dry_run = false
  let mut force = false
  let mut seen_target = false
  let mut seen_targets = false
  let mut seen_dry_run = false
  let mut seen_force = false
  let mut idx = 0
  while idx < argv.length() {
    let arg = argv[idx]
    match arg {
      "install" if idx == 0 => ()
      "--dry-run" => {
        guard !seen_dry_run else { fail("duplicate argument: --dry-run") }
        dry_run = true
        seen_dry_run = true
      }
      "--force" => {
        guard !seen_force else { fail("duplicate argument: --force") }
        force = true
        seen_force = true
      }
      "--bin-dir" => {
        idx = idx + 1
        guard idx < argv.length() && argv[idx] != "" else {
          fail("--bin-dir requires a directory")
        }
        guard directory is None else { fail("duplicate argument: --bin-dir") }
        directory = Some(argv[idx])
      }
      "--target" => {
        idx = idx + 1
        guard idx < argv.length() else { fail("--target requires a target") }
        guard !seen_target else { fail("duplicate argument: --target") }
        guard !seen_targets else {
          fail("--target and --targets are mutually exclusive")
        }
        seen_target = true
        validate_target(argv[idx])
        target = Some(argv[idx])
      }
      "--targets" => {
        idx = idx + 1
        guard idx < argv.length() else { fail("--targets requires a target list") }
        guard !seen_targets else { fail("duplicate argument: --targets") }
        guard !seen_target else {
          fail("--target and --targets are mutually exclusive")
        }
        seen_targets = true
        target = Some(parse_target_list(argv[idx]).join(","))
      }
      "--version" => {
        idx = idx + 1
        guard idx < argv.length() else { fail("--version requires a version") }
        guard version is None else { fail("duplicate argument: --version") }
        version = Some(argv[idx])
      }
      "--pkg-url" => {
        idx = idx + 1
        guard idx < argv.length() else { fail("--pkg-url requires a template") }
        guard pkg_url is None else { fail("duplicate argument: --pkg-url") }
        pkg_url = Some(argv[idx])
      }
      "--pkg-fmt" => {
        idx = idx + 1
        guard idx < argv.length() else { fail("--pkg-fmt requires a format") }
        guard pkg_fmt is None else { fail("duplicate argument: --pkg-fmt") }
        validate_archive_format(argv[idx])
        pkg_fmt = Some(argv[idx])
      }
      "--bin-path" => {
        idx = idx + 1
        guard idx < argv.length() else { fail("--bin-path requires a path") }
        guard bin_path is None else { fail("duplicate argument: --bin-path") }
        validate_member_path(argv[idx])
        bin_path = Some(argv[idx])
      }
      "--module" => {
        idx = idx + 1
        guard idx < argv.length() else {
          fail("--module requires owner/module")
        }
        guard module_path is None else { fail("duplicate argument: --module") }
        let parts = argv[idx].split("/").collect()
        guard parts.length() == 2 &&
          valid_id(parts[0].to_owned()) &&
          valid_id(parts[1].to_owned()) else {
          fail("--module must be owner/module")
        }
        module_path = Some(argv[idx])
      }
      "--manifest-path" => {
        idx = idx + 1
        guard idx < argv.length() && argv[idx] != "" else {
          fail("--manifest-path requires a file")
        }
        guard manifest_path is None else {
          fail("duplicate argument: --manifest-path")
        }
        manifest_path = Some(argv[idx])
      }
      _ => {
        guard !arg.has_prefix("-") else {
          fail("unrecognized or duplicate argument: \{arg}")
        }
        raw_coordinates.push(arg)
      }
    }
    idx = idx + 1
  }
  guard raw_coordinates.length() > 0 else { fail("missing package coordinate") }
  let coordinates : Array[InstallCoordinate] = []
  match module_path {
    Some(module_name) =>
      for raw in raw_coordinates {
        coordinates.push(Mooncakes(parse_module_package(module_name, raw)))
      }
    None =>
      for raw in raw_coordinates {
        coordinates.push(parse_coordinate(raw))
      }
  }
  if version is Some(_) {
    guard coordinates.length() == 1 else {
      fail(
        "--version applies to one package; use @VERSION on each package in a batch",
      )
    }
    match coordinates[0] {
      GitHub(pkg) =>
        if pkg.version is Some(_) {
          fail("cannot combine --version with @tag")
        }
      Mooncakes(pkg) =>
        if pkg.version is Some(_) {
          fail("cannot combine --version with @version")
        }
    }
  }
  if manifest_path is Some(_) {
    guard coordinates.length() == 1 else {
      fail("--manifest-path can be used with one package at a time")
    }
    guard coordinates[0] is Mooncakes(_) else {
      fail("--manifest-path requires a Mooncakes package coordinate")
    }
  }
  {
    coordinates,
    directory,
    dry_run,
    force,
    target,
    version,
    pkg_url,
    pkg_fmt,
    bin_path,
    module_path,
    manifest_path,
  }
}

///|
pub fn validate_target(target : String) -> Unit raise {
  guard target == "linux-x86_64" ||
    target == "linux-aarch64" ||
    target == "darwin-x86_64" ||
    target == "darwin-aarch64" else {
    fail("unsupported target: \{target}")
  }
}

///|
/// Keep the public BatchOptions shape source-compatible: --targets is stored
/// in its existing target field as a comma-separated, validated sequence.
pub fn parse_target_list(value : String) -> Array[String] raise {
  let entries = value.split(",").collect()
  guard entries.length() > 0 else { fail("--targets requires a target list") }
  let targets : Array[String] = []
  for entry in entries {
    let candidate = entry.trim().to_owned()
    guard candidate != "" else {
      fail("--targets contains an empty target")
    }
    validate_target(candidate)
    guard !targets.contains(candidate) else {
      fail("duplicate target in --targets: \{candidate}")
    }
    targets.push(candidate)
  }
  targets
}

///|
async fn require_platform() -> String {
  let (os_status, os_out) = @process.collect_stdout("uname", ["-s"])
  guard os_status == 0 else { fail("uname -s failed") }
  let (cpu_status, cpu_out) = @process.collect_stdout("uname", ["-m"])
  guard cpu_status == 0 else { fail("uname -m failed") }
  platform_key(
    os_out.text().trim().to_owned(),
    cpu_out.text().trim().to_owned(),
  )
}

///|
fn target_directory(dir_override : String?) -> String raise {
  match dir_override {
    Some(dir) => {
      guard dir != "" && dir.has_prefix("/") else {
        fail("--bin-dir must be an absolute path")
      }
      dir
    }
    None =>
      match @env.get_env_var("MOON_BINSTALL_DIR") {
        Some(dir) => {
          guard dir != "" && dir.has_prefix("/") else {
            fail("MOON_BINSTALL_DIR must be an absolute path")
          }
          dir
        }
        None =>
          match @env.get_env_var("HOME") {
            Some(home) => home + "/.local/bin"
            None => fail("HOME is not set; provide --bin-dir")
          }
      }
  }
}

///|
/// Fail if curl refuses the transfer, rather than treating a 404 body as a
/// binary. Keep every request HTTPS, redirect only to HTTPS, and bound time.
async fn download(url : String, path : String) -> Unit {
  guard url.has_prefix("https://") else {
    fail("refusing a non-HTTPS download URL")
  }
  let args = [
    "--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir",
    "=https", "--max-redirs", "5", "--connect-timeout", "15", "--max-time", "300",
    "--max-filesize", "268435456", "--output", path, url,
  ]
  let status = @process.run("curl", args)
  guard status == 0 else { fail("curl download failed (exit \{status})") }
  let size = @fs.file_size(path)
  guard size > 0L && size <= 268435456L else {
    fail("downloaded asset has an invalid size")
  }
}

///|
async fn fetch_text(url : String, accept_json : Bool) -> String? {
  guard url.has_prefix("https://") else { fail("refusing a non-HTTPS request") }
  let headers = if accept_json {
    [
      "--header", "Accept: application/vnd.github+json", "--header", "User-Agent: moon-binstall/0.1",
    ]
  } else {
    ["--header", "User-Agent: moon-binstall/0.1"]
  }
  let args = [
      "--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir",
      "=https", "--max-redirs", "5", "--connect-timeout", "15", "--max-time", "30",
      "--max-filesize", "16777216",
    ] +
    headers +
    [url]
  let response = @shell.Cmd("curl", args).output(
    timeout_ms=30000,
    max_output_bytes=16777216,
  )
  let code = response.exit_code()
  if code == 22 {
    return None
  }
  guard code == 0 else {
    fail("HTTPS request failed (curl exit \{code}): \{url}")
  }
  Some(@utf8.decode(response.stdout_bytes()))
}

///|
async fn verify_digest(path : String, expected : String) -> Unit {
  guard expected.has_prefix("sha256:") &&
    valid_sha256_hex(expected[7:].to_owned()) else {
    fail("release asset has no valid SHA-256 digest")
  }
  let bytes = @fs.read_file(path).binary()
  let actual = "sha256:" + @crypto.bytes_to_hex_string(@crypto.sha256(bytes))
  guard actual == "sha256:" + expected[7:].to_owned().to_lower() else {
    fail("SHA-256 verification failed: expected \{expected}, got \{actual}")
  }
}

///|
fn github_release_api(
  owner : String,
  repo : String,
  tag : String?,
) -> String raise {
  guard valid_id(owner) && valid_id(repo) else {
    fail("unsafe GitHub repository")
  }
  let base = "https://api.github.com/repos/\{owner}/\{repo}/releases"
  match tag {
    Some(value) => {
      guard valid_tag(value) else { fail("unsafe GitHub release tag") }
      base + "/tags/" + value
    }
    None => base + "/latest"
  }
}

///|
fn release_tag(payload : String) -> String raise {
  let document = @json.parse(payload)
  guard document is { "tag_name": String(tag), .. } && valid_tag(tag) else {
    fail("invalid GitHub release response")
  }
  tag
}

///|
fn version_from_tag(tag : String) -> String {
  if tag.has_prefix("v") {
    tag[1:].to_owned()
  } else {
    tag
  }
}

///|
fn module_leaf(module_path : String) -> String {
  let parts = module_path.split("/").collect()
  parts[parts.length() - 1].to_owned()
}

///|
pub struct ResolvedInstall {
  asset : ReleaseAsset
  binary : String
  format : String
  bin_path : String?
}

///|
/// Internal staging context keeps public ResolvedInstall unchanged while
/// carrying safe default member candidates for archive packages.
priv struct ResolvedInstallPlan {
  install : ResolvedInstall
  archive_candidates : Array[String]
  discover_archive_member : Bool
}

///|
/// Private transport seam for deterministic tests. Production entry points
/// always use HTTPS; fixtures can only be supplied by same-package tests.
#warnings("-struct_never_constructed")
priv struct FixtureTransport {
  responses : Array[(String, String)]
  files : Array[(String, String)]
}

///|
#warnings("-unused_constructor")
priv enum Transport {
  Https
  Fixture(FixtureTransport)
}

///|
fn fixture_lookup(
  entries : Array[(String, String)],
  key : String,
) -> String? raise {
  let mut result : String? = None
  for entry in entries {
    if entry.0 == key {
      guard result is None else {
        fail("duplicate fixture transport key: \{key}")
      }
      result = Some(entry.1)
    }
  }
  result
}

///|
async fn fetch_text_using(
  url : String,
  accept_json : Bool,
  transport : Transport,
) -> String? {
  match transport {
    Https => fetch_text(url, accept_json)
    Fixture(fixtures) => fixture_lookup(fixtures.responses, url)
  }
}

///|
async fn download_using(
  url : String,
  path : String,
  transport : Transport,
) -> Unit {
  match transport {
    Https => download(url, path)
    Fixture(fixtures) => {
      let source = match fixture_lookup(fixtures.files, url) {
        Some(value) => value
        None => fail("fixture transport has no asset for URL: \{url}")
      }
      @fs.write_file(
        path,
        @fs.read_file(source).binary(),
        create_mode=CreateNew,
      )
    }
  }
}

///|
#warnings("-unused_value")
fn resolve_asset_for_release(
  payload : String,
  owner : String,
  repo : String,
  binary : String,
  module_name : String,
  package_path : String,
  version_value : String,
  target : String,
  config : ArtifactConfig?,
  options : BatchOptions,
) -> ResolvedInstall raise {
  let config_set = match config {
    Some(value) => Some({ base: value, overrides: [] })
    None => None
  }
  resolve_asset_plan_for_release(
    payload, owner, repo, binary, module_name, package_path, version_value,
    target, config_set, options,
  ).install
}

///|
fn resolve_asset_plan_for_release(
  payload : String,
  owner : String,
  repo : String,
  binary : String,
  module_name : String,
  package_path : String,
  version_value : String,
  target : String,
  config_set : ArtifactConfigSet?,
  options : BatchOptions,
) -> ResolvedInstallPlan raise {
  let tag = release_tag(payload)
  let target_candidates = match options.target {
    Some(value) => parse_target_list(value)
    None => {
      validate_target(target)
      [target]
    }
  }
  match config_set {
    Some(config) =>
      validate_artifact_config_set_for_release(
        config, owner, repo, module_name, package_path, binary,
        version_value, tag, options.pkg_fmt,
      )
    None => ()
  }
  let mut selected_asset : (ReleaseAsset, String, ArtifactConfig?)? = None
  for candidate_target in target_candidates {
    // CLI options override a target-specific value, which in turn overrides
    // the package default. Resolve this for each ordered target independently.
    let candidate_config = match config_set {
      Some(config) => Some(artifact_config_for_target(config, candidate_target))
      None => None
    }
    let selected_template = match options.pkg_url {
      Some(value) => Some(value)
      None =>
        match candidate_config {
          Some(item) => item.pkg_url
          None => None
        }
    }
    let requested_format = match options.pkg_fmt {
      Some(value) => Some(value)
      None =>
        match candidate_config {
          Some(item) => item.pkg_fmt
          None => None
        }
    }
    let format_hint = match requested_format {
      Some(value) => value
      None =>
        match selected_template {
          Some(template) => infer_archive_format(template)
          None => "bin"
        }
    }
    let names = match selected_template {
      Some(template) => {
        let suffix = archive_suffix(format_hint)
        let expanded = expand_artifact_template(
          template, owner, repo, module_name, package_path, binary,
          version_value, candidate_target, suffix,
        )
        [artifact_url_asset_name(expanded, owner, repo, tag)]
      }
      None => {
        let names = default_artifact_names_for_format(
          binary, version_value, candidate_target, requested_format,
        )
        if module_name != binary {
          let module_names = default_artifact_names_for_format(
            module_name, version_value, candidate_target, requested_format,
          )
          for name in module_names {
            if !names.contains(name) {
              names.push(name)
            }
          }
        }
        names
      }
    }
    match
      resolve_release_names_optional(
        payload, owner, repo, names, Some(tag),
      ) {
      Some(asset) => {
        selected_asset = Some((asset, candidate_target, candidate_config))
        break
      }
      None => ()
    }
  }
  let (asset, matched_target, matched_config) = match selected_asset {
    Some(value) => value
    None => fail("no matching prebuilt asset in release \{tag}")
  }
  let requested_format = match options.pkg_fmt {
    Some(value) => Some(value)
    None =>
      match matched_config {
        Some(item) => item.pkg_fmt
        None => None
      }
  }
  let format = match requested_format {
    Some(value) => value
    None => infer_archive_format(asset.name)
  }
  let bin_path_template = match options.bin_path {
    Some(value) => Some(value)
    None =>
      match matched_config {
        Some(item) => item.bin_path
        None => None
      }
  }
  let discover_archive_member = format != "bin" && bin_path_template is None
  let bin_path = if format == "bin" {
    None
  } else {
    Some(
      match bin_path_template {
        Some(value) =>
          expand_artifact_member_template(
            value,
            owner,
            repo,
            module_name,
            package_path,
            binary,
            version_value,
            matched_target,
            archive_suffix(format),
          )
        None => binary
      },
    )
  }
  if bin_path is Some(path) {
    validate_member_path(path)
  }
  let archive_candidates = if discover_archive_member {
    default_archive_member_candidates(
      module_name, package_path, binary, version_value, matched_target,
    )
  } else {
    []
  }
  {
    install: { asset, binary, format, bin_path, },
    archive_candidates,
    discover_archive_member,
  }
}

///|
/// Validate every declared target template against the repository and tag,
/// even if a CLI option or an earlier target later wins selection.
fn validate_artifact_config_set_for_release(
  config_set : ArtifactConfigSet,
  owner : String,
  repo : String,
  module_name : String,
  package_path : String,
  binary : String,
  version : String,
  tag : String,
  cli_format : String?,
) -> Unit raise {
  for target in [
    "linux-x86_64", "linux-aarch64", "darwin-x86_64", "darwin-aarch64",
  ] {
    let config = artifact_config_for_target(config_set, target)
    let format_hint = match cli_format {
      Some(value) => value
      None =>
        match config.pkg_fmt {
          Some(value) => value
          None =>
            match config.pkg_url {
              Some(template) => infer_archive_format(template)
              None => "bin"
            }
        }
    }
    match config.pkg_url {
      Some(template) => {
        let expanded = expand_artifact_template(
          template,
          owner,
          repo,
          module_name,
          package_path,
          binary,
          version,
          target,
          archive_suffix(format_hint),
        )
        ignore(artifact_url_asset_name(expanded, owner, repo, tag))
      }
      None => ()
    }
    match config.bin_path {
      Some(template) => {
        let expanded = expand_artifact_member_template(
          template,
          owner,
          repo,
          module_name,
          package_path,
          binary,
          version,
          target,
          archive_suffix(format_hint),
        )
        validate_member_path(expanded)
      }
      None => ()
    }
  }
}

///|
#warnings("-unused_value")
async fn resolve_package(
  coordinate : InstallCoordinate,
  options : BatchOptions,
  target : String,
  workspace : String,
  index : Int,
  transport : Transport,
) -> ResolvedInstall {
  resolve_package_plan(coordinate, options, target, workspace, index, transport).install
}

///|
async fn resolve_package_plan(
  coordinate : InstallCoordinate,
  options : BatchOptions,
  target : String,
  workspace : String,
  index : Int,
  transport : Transport,
) -> ResolvedInstallPlan {
  match coordinate {
    GitHub(pkg) => {
      let version = match options.version {
        Some(value) => Some(value)
        None => pkg.version
      }
      let api = github_release_api(pkg.owner, pkg.repo, version)
      let payload = match fetch_text_using(api, true, transport) {
        Some(value) => value
        None => fail("GitHub release lookup failed: \{api}")
      }
      let tag = release_tag(payload)
      match version {
        Some(expected) if tag != expected =>
          fail("GitHub returned tag \{tag}, expected \{expected}")
        _ => ()
      }
      let version_for_template = version_from_tag(tag)
      resolve_asset_plan_for_release(
        payload,
        pkg.owner,
        pkg.repo,
        pkg.binary,
        pkg.repo,
        pkg.repo,
        version_for_template,
        target,
        None,
        options,
      )
    }
    Mooncakes(pkg) => {
      let local_manifest = match options.manifest_path {
        Some(path) => Some(@fs.read_file(path).text())
        None => None
      }
      let (owner, repo, version, config_set) = match local_manifest {
        Some(payload) => {
          let repository = manifest_repository(payload, pkg.module_path)
          let (owner, repo) = parse_github_repository(repository)
          let version = match options.version {
            Some(value) => Some(value)
            None =>
              match pkg.version {
                Some(value) => Some(value)
                None => manifest_version(payload)
              }
          }
          let config_set = parse_artifact_config_set(
            payload,
            pkg.package_path,
            pkg.binary,
          )
          (owner, repo, version, config_set)
        }
        None => {
          let requested_version = match options.version {
            Some(value) => Some(value)
            None => pkg.version
          }
          let metadata_url = mooncakes_manifest_url(
            pkg.module_path,
            requested_version,
          )
          let metadata_payload = match
            fetch_text_using(metadata_url, false, transport) {
            Some(value) => value
            None =>
              fail("Mooncakes module release was not found: \{metadata_url}")
          }
          let registry_release = resolve_registry_release(
            metadata_payload,
            pkg.module_path,
            requested_version,
          )
          let (owner, repo) = parse_github_repository(
            registry_release.repository,
          )
          let source_path = workspace + "/module-\{index}.zip"
          download_using(
            mooncakes_source_url(pkg.module_path, registry_release.version),
            source_path,
            transport,
          )
          verify_sha256_hex(source_path, registry_release.checksum)
          let config_bytes = read_zip_member_optional_with_limit(
            source_path, "moon-binstall.json", 1048576,
          )
          let config_set = match config_bytes {
            Some(bytes) =>
              parse_artifact_config_set(
                @utf8.decode(bytes),
                pkg.package_path,
                pkg.binary,
              )
            None => None
          }
          (owner, repo, Some(registry_release.version), config_set)
        }
      }
      let binary = match config_set {
        Some(item) => item.base.binary
        None => pkg.binary
      }
      match version {
        Some(value) => {
          let preferred = if value.has_prefix("v") {
            value
          } else {
            "v" + value
          }
          let preferred_url = github_release_api(owner, repo, Some(preferred))
          let (payload, expected_tag) = match
            fetch_text_using(preferred_url, true, transport) {
            Some(payload) => (payload, preferred)
            None => {
              if preferred == value {
                fail(
                  "GitHub release was not found for \{pkg.module_path}@\{value}",
                )
              }
              let fallback_url = github_release_api(owner, repo, Some(value))
              match fetch_text_using(fallback_url, true, transport) {
                Some(payload) => (payload, value)
                None =>
                  fail(
                    "GitHub release was not found for \{pkg.module_path}@\{value}",
                  )
              }
            }
          }
          let actual_tag = release_tag(payload)
          guard actual_tag == expected_tag else {
            fail("GitHub returned tag \{actual_tag}, expected \{expected_tag}")
          }
          resolve_asset_plan_for_release(
            payload,
            owner,
            repo,
            binary,
            module_leaf(pkg.module_path),
            pkg.package_path,
            version_from_tag(actual_tag),
            target,
            config_set,
            options,
          )
        }
        None => {
          let api = github_release_api(owner, repo, None)
          let payload = match fetch_text_using(api, true, transport) {
            Some(value) => value
            None =>
              fail("latest GitHub release was not found for \{pkg.module_path}")
          }
          let tag = release_tag(payload)
          resolve_asset_plan_for_release(
            payload,
            owner,
            repo,
            binary,
            module_leaf(pkg.module_path),
            pkg.package_path,
            version_from_tag(tag),
            target,
            config_set,
            options,
          )
        }
      }
    }
  }
}

///|
async fn path_kind_no_follow(path : String) -> @fs.FileKind? {
  Some(@fs.kind(path, follow_symlink=false)) catch {
    @os_error.OSError(_) as err if err.is_ENOENT() => None
    err => raise err
  }
}

///|
async fn check_destination(path : String, force : Bool) -> Unit {
  match path_kind_no_follow(path) {
    Some(Regular) if force => ()
    Some(Regular) => fail("already exists: \{path} (use --force to replace)")
    Some(_) => fail("refusing to replace a non-regular file: \{path}")
    None => ()
  }
}

///|
pub struct StagedInstall {
  destination : String
  staging : String
  staging_dir : String
}

///|
/// Create an exclusive private directory beside the destination. Renaming
/// from this directory stays on the destination filesystem and never shares
/// staging paths between concurrent invocations.
async fn create_staging_directory_at(
  bin_dir : String,
  index : Int,
  stamp : String,
) -> String {
  let mut attempt = 0
  while attempt < 10000 {
    let path = bin_dir + "/.moon-binstall-stage-\{stamp}-\{index}-\{attempt}"
    try {
      @fs.mkdir(path, permission=0o700, allow_exist=false)
      return path
    } catch {
      @os_error.OSError(_) as err if err.is_EEXIST() => attempt = attempt + 1
      err => raise err
    }
  }
  fail("could not allocate a private staging directory")
}

///|
async fn create_staging_directory(bin_dir : String, index : Int) -> String {
  create_staging_directory_at(bin_dir, index, @async.now().to_string())
}

///|
async fn stage_install(
  plan : ResolvedInstallPlan,
  bin_dir : String,
  workspace : String,
  index : Int,
  force : Bool,
  transport : Transport,
) -> StagedInstall {
  let item = plan.install
  let destination = bin_dir + "/" + item.binary
  check_destination(destination, force)
  let archive_path = workspace + "/asset-\{index}"
  download_using(item.asset.url, archive_path, transport)
  verify_digest(archive_path, item.asset.digest)
  let binary = if plan.discover_archive_member {
    read_artifact_binary_from_candidates(
      archive_path, item.format, plan.archive_candidates,
    )
  } else {
    read_artifact_binary(archive_path, item.format, item.bin_path)
  }
  let staging_dir = create_staging_directory(bin_dir, index)
  let mut ownership_transferred = false
  defer (if !ownership_transferred {
    @fs.rmdir(staging_dir, recursive=true) catch {
      _ => ()
    }
  })
  let staging = staging_dir + "/" + item.binary
  @fs.write_file(staging, binary, create_mode=CreateNew, permission=0o600)
  @fs.chmod(staging, 0o755)
  ownership_transferred = true
  { destination, staging, staging_dir, }
}

///|
pub async fn install_many(options : BatchOptions) -> Unit {
  install_many_using(options, Https)
}

///|
async fn install_many_using(
  options : BatchOptions,
  transport : Transport,
) -> Unit {
  let target = match options.target {
    Some(value) => parse_target_list(value)[0]
    None => require_platform()
  }
  let workspace = @fs.tmpdir(prefix="moon-binstall")
  defer (@fs.rmdir(workspace, recursive=true) catch { _ => () })
  let resolved : Array[ResolvedInstallPlan] = []
  let binary_names : Array[String] = []
  for i = 0; i < options.coordinates.length(); i = i + 1 {
    let item = resolve_package_plan(
      options.coordinates[i],
      options,
      target,
      workspace,
      i,
      transport,
    )
    // Safe binary names are ASCII, so lowercase keys are portable. Apply the
    // check everywhere because default macOS filesystems are case-insensitive.
    let binary_key = item.install.binary.to_lower()
    guard !binary_names.contains(binary_key) else {
      fail(
        "multiple packages resolve to the same executable name (case-insensitive): \{item.install.binary}",
      )
    }
    binary_names.push(binary_key)
    resolved.push(item)
    println("Resolved \{item.install.asset.tag}: \{item.install.asset.name}")
  }
  let bin_dir = target_directory(options.directory)
  if options.dry_run {
    for plan in resolved {
      let item = plan.install
      println("Would install \{item.asset.url} -> \{bin_dir}/\{item.binary}")
    }
    return
  }
  @fs.mkdir(bin_dir, recursive=true, allow_exist=true)
  for plan in resolved {
    check_destination(bin_dir + "/" + plan.install.binary, options.force)
  }
  let staged : Array[StagedInstall] = []
  let pending : Array[Bool] = []
  defer (for i = 0; i < staged.length(); i = i + 1 {
    if pending[i] {
      @fs.remove(staged[i].staging) catch {
        _ => ()
      }
      @fs.rmdir(staged[i].staging_dir, recursive=true) catch {
        _ => ()
      }
    }
  })
  for i = 0; i < resolved.length(); i = i + 1 {
    let item = stage_install(
      resolved[i],
      bin_dir,
      workspace,
      i,
      options.force,
      transport,
    )
    staged.push(item)
    pending.push(true)
  }
  for i = 0; i < staged.length(); i = i + 1 {
    let item = staged[i]
    @fs.rename(item.staging, item.destination, replace=options.force)
    pending[i] = false
    @fs.rmdir(item.staging_dir, recursive=true) catch {
      _ => ()
    }
    println("Installed \{item.destination}")
  }
}

///|
pub async fn install(config : Options) -> Unit {
  install_many({
    coordinates: [GitHub(config.pkg)],
    directory: config.directory,
    dry_run: config.dry_run,
    force: config.force,
    target: None,
    version: None,
    pkg_url: None,
    pkg_fmt: None,
    bin_path: None,
    module_path: None,
    manifest_path: None,
  })
}

///|
pub async fn install_from_asset_file(
  asset_path : String,
  digest : String,
  format : String,
  bin_path : String?,
  binary : String,
  bin_dir : String,
  force : Bool,
) -> Unit {
  guard safe_binary_name(binary) else { fail("unsafe executable name") }
  guard bin_dir.has_prefix("/") else {
    fail("--bin-dir must be an absolute path")
  }
  @fs.mkdir(bin_dir, recursive=true, allow_exist=true)
  let destination = bin_dir + "/" + binary
  check_destination(destination, force)
  verify_digest(asset_path, digest)
  let content = read_artifact_binary(asset_path, format, bin_path)
  let staging_dir = create_staging_directory(bin_dir, 0)
  let mut owns_directory = true
  defer (if owns_directory {
    @fs.rmdir(staging_dir, recursive=true) catch {
      _ => ()
    }
  })
  let staging = staging_dir + "/" + binary
  @fs.write_file(staging, content, create_mode=CreateNew, permission=0o600)
  @fs.chmod(staging, 0o755)
  @fs.rename(staging, destination, replace=force)
  owns_directory = false
  @fs.rmdir(staging_dir, recursive=true) catch {
    _ => ()
  }
}

///|
pub async fn execute(argv : ArrayView[String]) -> Int {
  if argv.length() == 0 ||
    (
      argv.length() == 1 &&
      (argv[0] == "--help" || argv[0] == "-h" || argv[0] == "help")
    ) {
    println(usage())
    return 0
  }
  if argv.length() == 1 && argv[0] == "--version" {
    println("moon-binstall 0.1.2")
    return 0
  }
  let config = parse_batch_options(argv)
  install_many(config)
  0
}
