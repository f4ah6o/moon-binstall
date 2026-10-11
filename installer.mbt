///|
pub struct Options {
  pkg : Package
  directory : String?
  dry_run : Bool
  force : Bool
  skip_compat_check : Bool
}

///|
/// Multi-package CLI settings. The existing Options and install entry point
/// remain available to library callers.
pub struct BatchOptions {
  coordinates : Array[InstallCoordinate]
  directory : String?
  dry_run : Bool
  force : Bool
  skip_compat_check : Bool
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
    #|  --skip-compat-check   install even if the binary cannot run here
    #|
    #|  moon-binstall --help
    #|  moon binstall owner/module/package[@version]... [options]
    #|  moon binstall --help
    #|
    #|Environment: MOON_BINSTALL_DIR (default $HOME/.local/bin)
    #|
    #|Requires: curl >= 8.4.0; tar and matching codecs for tar archives;
    #|          zstd for tzstd; unzip/zipinfo for zip; macOS or Linux.
    #|Every release asset must include GitHub's SHA-256 digest.
  msg
}

///|
pub fn parse_options(argv : ArrayView[String]) -> Options raise {
  let mut coordinate = ""
  let mut directory : String? = None
  let mut dry_run = false
  let mut force = false
  let mut skip_compat_check = false
  let mut idx = 0
  while idx < argv.length() {
    let arg = argv[idx]
    match arg {
      "install" if idx == 0 => ()
      "--dry-run" => dry_run = true
      "--force" => force = true
      "--skip-compat-check" => skip_compat_check = true
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
  {
    pkg: parse_package(coordinate),
    directory,
    dry_run,
    force,
    skip_compat_check,
  }
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
  let mut skip_compat_check = false
  let mut seen_target = false
  let mut seen_targets = false
  let mut seen_dry_run = false
  let mut seen_force = false
  let mut seen_skip_compat_check = false
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
      "--skip-compat-check" => {
        guard !seen_skip_compat_check else {
          fail("duplicate argument: --skip-compat-check")
        }
        skip_compat_check = true
        seen_skip_compat_check = true
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
        guard idx < argv.length() else {
          fail("--targets requires a target list")
        }
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
    skip_compat_check,
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
    guard candidate != "" else { fail("--targets contains an empty target") }
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
  /// Matched release target, used for compatibility pre-checks.
  target : String
  /// Publisher-declared minimum glibc version for Linux binaries.
  glibc_min : String?
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
    Some(value) => Some({ base: value, overrides: [], })
    None => None
  }
  resolve_asset_plan_for_release(
    payload, owner, repo, binary, module_name, package_path, version_value, target,
    config_set, options,
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
        config,
        owner,
        repo,
        module_name,
        package_path,
        binary,
        version_value,
        tag,
        options.pkg_fmt,
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
          template, owner, repo, module_name, package_path, binary, version_value,
          candidate_target, suffix,
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
      resolve_release_names_optional(payload, owner, repo, names, Some(tag)) {
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
    target: matched_target,
    glibc_min: match matched_config {
      Some(item) => item.glibc_min
      None => None
    },
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
  for
    target in [
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
/// Return the ELF machine type when `binary` is a little-endian ELF file,
/// or None for other formats. e_machine sits at offset 18.
fn elf_machine(binary : Bytes) -> Int? {
  guard binary.length() >= 20 &&
    binary[0].to_int() == 0x7f &&
    binary[1] == b'E' &&
    binary[2] == b'L' &&
    binary[3] == b'F' &&
    binary[5].to_int() == 1 else {
    return None
  }
  Some(binary[18].to_int() | (binary[19].to_int() << 8))
}

///|
/// Dependencies extracted from a little-endian ELF64 file without executing
/// it: the PT_INTERP loader path, DT_NEEDED sonames, DT_RUNPATH/DT_RPATH
/// search paths, required symbol versions by provider library, and the
/// version names this file itself defines.
priv struct ElfDeps {
  interp : String?
  needed : Array[String]
  mut runpath : String?
  // True when `runpath` came from DT_RPATH because DT_RUNPATH is absent —
  // legacy RPATH is searched before LD_LIBRARY_PATH, RUNPATH after it.
  mut rpath_first : Bool
  verneed : Array[(String, String)]
  verdef : Array[String]
}

///|
fn elf_u16le(binary : Bytes, offset : Int) -> Int {
  binary[offset].to_int() | (binary[offset + 1].to_int() << 8)
}

///|
fn elf_u32le(binary : Bytes, offset : Int) -> Int {
  binary[offset].to_int() |
  (binary[offset + 1].to_int() << 8) |
  (binary[offset + 2].to_int() << 16) |
  (binary[offset + 3].to_int() << 24)
}

///|
fn elf_u64le(binary : Bytes, offset : Int) -> Int64 {
  let mut value = 0L
  for i = 0; i < 8; i = i + 1 {
    value = value | (binary[offset + i].to_int().to_int64() << (i * 8))
  }
  value
}

///|
fn elf_cstr(binary : Bytes, offset : Int) -> String {
  let bytes : Array[Byte] = []
  let mut cursor = offset
  while cursor < binary.length() && binary[cursor].to_int() != 0 {
    bytes.push(binary[cursor])
    cursor = cursor + 1
  }
  @utf8.decode_lossy(Bytes::from_array(bytes))
}

///|
/// Map an ELF virtual address to a file offset through the PT_LOAD segments.
fn elf_vaddr_offset(
  loads : Array[(Int64, Int64, Int64)],
  target : Int64,
) -> Int64? {
  for segment in loads {
    let (vaddr, offset, filesz) = segment
    if target >= vaddr && target < vaddr + filesz {
      return Some(offset + (target - vaddr))
    }
  }
  None
}

///|
/// Parse a little-endian ELF64 file's program headers and .dynamic section
/// for its runtime dependencies, or None for other formats. Malformed or
/// truncated input yields None rather than an error — the caller then
/// skips the check instead of rejecting the artifact.
fn parse_elf64_deps(binary : Bytes) -> ElfDeps? {
  guard binary.length() >= 64 &&
    binary[0].to_int() == 0x7f &&
    binary[1] == b'E' &&
    binary[2] == b'L' &&
    binary[3] == b'F' &&
    binary[4].to_int() == 2 &&
    binary[5].to_int() == 1 else {
    return None
  }
  let phoff = elf_u64le(binary, 32).to_int()
  let phentsize = elf_u16le(binary, 54)
  let phnum = elf_u16le(binary, 56)
  guard phoff >= 0 && phnum > 0 && phnum < 4096 && phentsize >= 56 else {
    return None
  }
  let loads : Array[(Int64, Int64, Int64)] = []
  let mut interp : String? = None
  let mut dyn_offset = -1
  let mut dyn_size = 0L
  for i = 0; i < phnum; i = i + 1 {
    let p = phoff + i * phentsize
    guard p + 56 <= binary.length() else { return None }
    let ptype = elf_u32le(binary, p)
    if ptype == 1 {
      loads.push(
        (
          elf_u64le(binary, p + 16),
          elf_u64le(binary, p + 8),
          elf_u64le(binary, p + 32),
        ),
      )
    } else if ptype == 3 {
      let offset = elf_u64le(binary, p + 8)
      let size = elf_u64le(binary, p + 32)
      if size > 0L &&
        offset >= 0L &&
        offset + size <= binary.length().to_int64() {
        interp = Some(elf_cstr(binary, offset.to_int()))
      }
    } else if ptype == 2 {
      dyn_offset = elf_u64le(binary, p + 8).to_int()
      dyn_size = elf_u64le(binary, p + 32)
    }
  }
  let deps : ElfDeps = {
    interp,
    needed: [],
    runpath: None,
    rpath_first: false,
    verneed: [],
    verdef: [],
  }
  if dyn_offset >= 0 {
    parse_dynamic_deps(binary, dyn_offset, dyn_size, loads, deps)
  }
  Some(deps)
}

///|
/// Walk the .dynamic entries for DT_NEEDED, DT_STRTAB, DT_RPATH,
/// DT_RUNPATH, DT_VERNEED/NUM and DT_VERDEF/NUM, resolving string-table
/// references through PT_LOAD segments into `deps`.
fn parse_dynamic_deps(
  binary : Bytes,
  dyn_offset : Int,
  dyn_size : Int64,
  loads : Array[(Int64, Int64, Int64)],
  deps : ElfDeps,
) -> Unit {
  let needed_offsets : Array[Int] = []
  let mut strtab_vaddr = -1L
  let mut rpath_offset = -1L
  let mut runpath_offset = -1L
  let mut verneed_vaddr = -1L
  let mut verneed_num = 0L
  let mut verdef_vaddr = -1L
  let mut verdef_num = 0L
  let count = (dyn_size / 16).to_int()
  for i = 0; i < count; i = i + 1 {
    let entry = dyn_offset + i * 16
    if entry + 16 > binary.length() {
      break
    }
    let tag = elf_u64le(binary, entry)
    let value = elf_u64le(binary, entry + 8)
    if tag == 0L {
      break
    } else if tag == 1L {
      needed_offsets.push(value.to_int())
    } else if tag == 5L {
      strtab_vaddr = value
    } else if tag == 15L {
      // DT_RPATH
      rpath_offset = value
    } else if tag == 29L {
      // DT_RUNPATH
      runpath_offset = value
    } else if tag == 1879048188L {
      // DT_VERDEF (0x6ffffffc)
      verdef_vaddr = value
    } else if tag == 1879048189L {
      // DT_VERDEFNUM (0x6ffffffd)
      verdef_num = value
    } else if tag == 1879048190L {
      // DT_VERNEED (0x6ffffffe)
      verneed_vaddr = value
    } else if tag == 1879048191L {
      // DT_VERNEEDNUM (0x6fffffff)
      verneed_num = value
    }
  }
  guard strtab_vaddr >= 0L else { return }
  let strtab = match elf_vaddr_offset(loads, strtab_vaddr) {
    Some(base) => base.to_int()
    None => return
  }
  for offset in needed_offsets {
    deps.needed.push(elf_cstr(binary, strtab + offset))
  }
  // DT_RUNPATH supersedes DT_RPATH in the loader search order.
  if runpath_offset >= 0L {
    deps.runpath = Some(elf_cstr(binary, strtab + runpath_offset.to_int()))
  } else if rpath_offset >= 0L {
    deps.runpath = Some(elf_cstr(binary, strtab + rpath_offset.to_int()))
    deps.rpath_first = true
  }
  if verneed_vaddr >= 0L {
    match elf_vaddr_offset(loads, verneed_vaddr) {
      Some(base) =>
        collect_verneed(
          binary,
          base.to_int(),
          verneed_num.to_int(),
          strtab,
          deps.verneed,
        )
      None => ()
    }
  }
  if verdef_vaddr >= 0L {
    match elf_vaddr_offset(loads, verdef_vaddr) {
      Some(base) =>
        collect_verdef(
          binary,
          base.to_int(),
          verdef_num.to_int(),
          strtab,
          deps.verdef,
        )
      None => ()
    }
  }
}

///|
/// Collect (provider soname, required version) pairs from .gnu.version_r.
/// Each Elf64_Verneed is 16 bytes (vn_file/vn_aux/vn_next are u32) and each
/// Elf64_Vernaux is 16 bytes (vna_name/vna_next are u32). All version
/// namespaces are recorded — GLIBCXX_*, CXXABI_* and others, not just GLIBC_*.
fn collect_verneed(
  binary : Bytes,
  offset : Int,
  count : Int,
  strtab : Int,
  out : Array[(String, String)],
) -> Unit {
  let mut cursor = offset
  for i = 0; i < count; i = i + 1 {
    if cursor + 16 > binary.length() {
      break
    }
    let vn_cnt = elf_u16le(binary, cursor + 2)
    let provider = elf_cstr(binary, strtab + elf_u32le(binary, cursor + 4))
    let vn_aux = elf_u32le(binary, cursor + 8)
    let vn_next = elf_u32le(binary, cursor + 12)
    let mut aux = cursor + vn_aux
    for j = 0; j < vn_cnt; j = j + 1 {
      if aux + 16 > binary.length() {
        break
      }
      let version = elf_cstr(binary, strtab + elf_u32le(binary, aux + 8))
      if version != "" {
        out.push((provider, version))
      }
      let vna_next = elf_u32le(binary, aux + 12)
      if vna_next == 0 {
        break
      }
      aux = aux + vna_next
    }
    if vn_next == 0 {
      break
    }
    cursor = cursor + vn_next
  }
}

///|
/// Collect the version names a file defines in .gnu.version_d. Each
/// Elf64_Verdef is 20 bytes (vd_aux/vd_next are u32) and each Elf64_Verdaux
/// is 8 bytes (vda_name/vda_next are u32).
fn collect_verdef(
  binary : Bytes,
  offset : Int,
  count : Int,
  strtab : Int,
  out : Array[String],
) -> Unit {
  let mut cursor = offset
  for i = 0; i < count; i = i + 1 {
    if cursor + 20 > binary.length() {
      break
    }
    let vd_cnt = elf_u16le(binary, cursor + 6)
    let vd_aux = elf_u32le(binary, cursor + 12)
    let vd_next = elf_u32le(binary, cursor + 16)
    let mut aux = cursor + vd_aux
    for j = 0; j < vd_cnt; j = j + 1 {
      if aux + 8 > binary.length() {
        break
      }
      let name = elf_cstr(binary, strtab + elf_u32le(binary, aux))
      if name != "" {
        out.push(name)
      }
      let vda_next = elf_u32le(binary, aux + 4)
      if vda_next == 0 {
        break
      }
      aux = aux + vda_next
    }
    if vd_next == 0 {
      break
    }
    cursor = cursor + vd_next
  }
}

///|
/// The host Linux kernel identifier (true when `uname -s` reports Linux).
async fn host_linux() -> Bool {
  let (status, out) = @process.collect_stdout("uname", ["-s"]) catch {
    _ => return false
  }
  status == 0 && out.text().trim() == "Linux"
}

///|
/// The host ELF e_machine value for the architectures moon-binstall ships,
/// or None on other platforms.
async fn host_machine() -> Int? {
  let (status, out) = @process.collect_stdout("uname", ["-m"]) catch {
    _ => return None
  }
  guard status == 0 else { return None }
  match out.text().trim() {
    "x86_64" | "amd64" => Some(62)
    "aarch64" | "arm64" => Some(183)
    _ => None
  }
}

///|
/// musl loader paths for the architectures moon-binstall ships. Their
/// presence means the host runs musl even when no `ldd` exists.
fn musl_loader_paths() -> Array[String] {
  [
    "/lib/ld-musl-x86_64.so.1", "/lib/ld-musl-aarch64.so.1", "/lib/libc.musl-x86_64.so.1",
    "/lib/libc.musl-aarch64.so.1",
  ]
}

///|
async fn musl_by_loader() -> String? {
  for path in musl_loader_paths() {
    if @fs.exists(path) {
      return Some("musl")
    }
  }
  None
}

///|
/// Identify the host libc: "musl", or a glibc version like "2.35".
/// `ldd --version` output is read from both streams because musl's ldd
/// prints its banner on stderr and exits nonzero. When ldd is absent or
/// unhelpful, known musl loader paths are probed instead — no executable
/// under inspection is ever run.
async fn host_libc() -> String? {
  let output = @shell.Cmd("ldd", ["--version"]).output(
    timeout_ms=15000,
    max_output_bytes=65536,
  ) catch {
    _ => return musl_by_loader()
  }
  match parse_host_libc(output.stdout() + "\n" + output.stderr()) {
    Some(value) => Some(value)
    None => musl_by_loader()
  }
}

///|
/// Soname → candidate paths of the host loader cache (`ldconfig -p`,
/// non-executing — it only reads /etc/ld.so.cache). One soname can map to
/// several ABI variants on multilib hosts (e.g. x86-64 and i386 libc.so.6),
/// so every candidate is kept in listed order for ABI-aware selection.
async fn ldconfig_map() -> Map[String, Array[String]] {
  let map : Map[String, Array[String]] = Map([])
  let output = @shell.Cmd("ldconfig", ["-p"]).output(
    timeout_ms=15000,
    max_output_bytes=4194304,
  ) catch {
    _ => return map
  }
  for line in output.stdout().split("\n") {
    let text = line.trim().to_owned()
    if !text.contains("=>") {
      continue
    }
    let parts = text.split("=>").collect()
    let soname = parts[0].trim().split(" ").iter().next().unwrap_or("")
    let path = parts[1].trim().to_owned()
    if soname != "" && path != "" {
      match map.get(soname.to_owned()) {
        Some(list) => if !list.contains(path) { list.push(path) }
        None => map[soname.to_owned()] = [path]
      }
    }
  }
  map
}

///|
/// Library directories checked when no ldconfig cache is available.
async fn library_dirs() -> Array[String] {
  let dirs = ["/lib", "/usr/lib", "/usr/local/lib", "/lib64", "/usr/lib64"]
  let (status, out) = @process.collect_stdout("uname", ["-m"]) catch {
    _ => return dirs
  }
  if status == 0 {
    let triplet = match out.text().trim() {
      "x86_64" | "amd64" => "x86_64-linux-gnu"
      "aarch64" | "arm64" => "aarch64-linux-gnu"
      _ => ""
    }
    if triplet != "" {
      dirs.push("/lib/" + triplet)
      dirs.push("/usr/lib/" + triplet)
    }
  }
  dirs
}

///|
/// The single directory name `$LIB`/`${LIB}` expands to on this host.
/// glibc substitutes exactly one distro-specific value — "lib/<triplet>"
/// on Debian multiarch, "lib64" on Fedora-style layouts — so probing
/// which layout directory exists picks the same expansion the real
/// loader would make; offering several candidates would accept a
/// library the loader cannot actually find.
async fn lib_token_names(host : Int) -> Array[String] {
  let triplet = match host {
    62 => "x86_64-linux-gnu"
    183 => "aarch64-linux-gnu"
    _ => ""
  }
  if triplet != "" && @fs.exists("/lib/" + triplet) {
    return ["lib/" + triplet]
  }
  if @fs.exists("/lib64") {
    return ["lib64"]
  }
  ["lib"]
}

///|
/// Expand the DT_RUNPATH/DT_RPATH search list into directories to probe.
/// `$ORIGIN` and the equivalent `${ORIGIN}` resolve against the directory
/// the object will live in (the binary's final install directory, or the
/// directory of a resolved transitive provider). `$LIB`/`${LIB}` expands
/// to each `lib_tokens` directory name in turn. Entries still containing
/// other `$` tokens ($PLATFORM) or relative paths are ignored — they
/// resolve against an unknown context.
fn expand_runpath(
  runpath : String?,
  origin : String,
  lib_tokens : Array[String],
) -> Array[String] {
  let dirs : Array[String] = []
  let value = match runpath {
    Some(text) => text
    None => return dirs
  }
  for entry in value.split(":") {
    let dir = entry.trim().to_owned()
    if dir == "" {
      continue
    }
    if dir.contains("$") {
      let expanded = dir
        .replace_all(old="${ORIGIN}", new=origin)
        .replace_all(old="$ORIGIN", new=origin)
      if expanded.contains("${LIB}") || expanded.contains("$LIB") {
        // One rpath entry becomes several candidate directories, one per
        // plausible $LIB value, kept in preference order.
        for token in lib_tokens {
          let candidate = expanded
            .replace_all(old="${LIB}", new=token)
            .replace_all(old="$LIB", new=token)
          if !candidate.contains("$") && candidate.has_prefix("/") {
            dirs.push(candidate)
          }
        }
      } else if !expanded.contains("$") && expanded.has_prefix("/") {
        dirs.push(expanded)
      }
    } else if dir.has_prefix("/") {
      dirs.push(dir)
    }
  }
  dirs
}

///|
/// Merge the DT_RPATH tier, LD_LIBRARY_PATH and the DT_RUNPATH tier in
/// the loader's order: the RPATH tier (the object's own DT_RPATH followed
/// by the ancestors' it inherited) is searched first, then the
/// environment, then the object's own DT_RUNPATH. Returns a fresh list —
/// callers iterate it for several sonames.
fn library_search_dirs(
  rpath_dirs : Array[String],
  env_dirs : Array[String],
  runpath_dirs : Array[String],
) -> Array[String] {
  let merged : Array[String] = []
  for dir in rpath_dirs {
    merged.push(dir)
  }
  for dir in env_dirs {
    merged.push(dir)
  }
  for dir in runpath_dirs {
    merged.push(dir)
  }
  merged
}

///|
/// Whether `head` — at least `phoff + phnum * phentsize` bytes of a file
/// of `file_size` bytes — describes a usable little-endian ELF64 shared
/// object for e_machine `host`: a complete ELF header and program-header
/// table plus at least one PT_LOAD segment lying fully inside the file.
/// A truncated or wrong-architecture ELF, a 32-bit ELF, a non-ELF file and
/// an ET_REL/ET_EXEC object all fail the real loader too, so they fail here.
fn elf64_usable(head : Bytes, file_size : Int64, host : Int) -> Bool {
  if head.length() < 64 {
    return false
  }
  if head[0].to_int() != 0x7f ||
    head[1] != b'E' ||
    head[2] != b'L' ||
    head[3] != b'F' ||
    head[4].to_int() != 2 ||
    head[5].to_int() != 1 ||
    // ET_DYN: both ld.so loaders and shared libraries.
    elf_u16le(head, 16) != 3 ||
    elf_u16le(head, 18) != host ||
    elf_u16le(head, 52) != 64 {
    return false
  }
  let phoff = elf_u64le(head, 32)
  let phentsize = elf_u16le(head, 54)
  let phnum = elf_u16le(head, 56)
  let table_end = phoff + phnum.to_int64() * phentsize.to_int64()
  if phoff <= 0L ||
    phnum < 1 ||
    phnum >= 4096 ||
    phentsize < 56 ||
    table_end > head.length().to_int64() ||
    table_end > file_size {
    return false
  }
  let mut loads = 0
  for i = 0; i < phnum; i = i + 1 {
    let p = phoff.to_int() + i * phentsize
    if elf_u32le(head, p) == 1 {
      loads = loads + 1
      let offset = elf_u64le(head, p + 8)
      let filesz = elf_u64le(head, p + 32)
      if filesz <= 0L || offset < 0L || offset + filesz > file_size {
        return false
      }
    }
  }
  loads > 0
}

///|
/// Whether the file at `path` is a usable host-architecture ELF64 shared
/// object — required of both the PT_INTERP loader and resolved DT_NEEDED
/// libraries. The complete program-header table and the PT_LOAD ranges are
/// validated against the open file's size (fstat, so symlinks to a loader
/// report their target's size), so a truncated loader does not slip
/// through on its first bytes alone. The regular-file check happens before
/// open: a FIFO or device named by an untrusted DT_NEEDED or PT_INTERP
/// string could block a read-only open.
async fn elf_file_usable(path : String, host : Int) -> Bool {
  guard @fs.kind(path) is Regular else { return false }
  let file = @fs.open(path, mode=ReadOnly) catch { _ => return false }
  let size = file.size() catch {
    _ => {
      file.close()
      return false
    }
  }
  let header = file.read_exactly_at(64, position=0L) catch {
    _ => {
      file.close()
      return false
    }
  }
  // Size the full header+phdr read from the declared table bounds.
  let phoff = elf_u64le(header, 32)
  let phentsize = elf_u16le(header, 54)
  let phnum = elf_u16le(header, 56)
  let needed = phoff + phnum.to_int64() * phentsize.to_int64()
  if needed <= 0L || needed > size || needed > 1048576L {
    file.close()
    return false
  }
  let head = file.read_exactly_at(needed.to_int(), position=0L) catch {
    _ => {
      file.close()
      return false
    }
  }
  file.close()
  elf64_usable(head, size, host)
}

///|
/// Directories from a colon-separated LD_LIBRARY_PATH value. Empty entries
/// and relative paths are skipped: they resolve against the eventual
/// runtime working directory, which the installer cannot know.
fn ld_library_dirs(value : String?) -> Array[String] {
  let dirs : Array[String] = []
  let text = match value {
    Some(env) => env
    None => return dirs
  }
  for entry in text.split(":") {
    let dir = entry.trim().to_owned()
    if dir != "" && dir.has_prefix("/") {
      dirs.push(dir)
    }
  }
  dirs
}

///|
/// Pick the first candidate library the host can actually load, like
/// ld.so skipping an incompatible file (wrong e_machine, not an ELF64
/// ET_DYN) it meets on the search path. The first regular-but-unusable
/// path seen is recorded into `first_unusable` rather than returned: a
/// foreign-architecture file in an early search location must not shadow
/// a compatible library that exists in a later search tier.
async fn pick_usable(
  paths : Array[String],
  host : Int,
  first_unusable : Ref[String?],
) -> String? {
  for path in paths {
    if !(@fs.exists(path) && @fs.kind(path) is Regular) {
      continue
    }
    if first_unusable.val is None {
      first_unusable.val = Some(path)
    }
    if elf_file_usable(path, host) {
      return Some(path)
    }
  }
  None
}

///|
/// Resolve a DT_NEEDED soname to a host path. `search_dirs` already merges
/// the RPATH tier, LD_LIBRARY_PATH and the object's RUNPATH directories in
/// loader order; then the ldconfig cache (which can hold several ABI
/// variants of one soname), and finally the usual library directories. In
/// every location an incompatible ELF is skipped just like ld.so skips it,
/// and the unusable-file fallback is deferred until all tiers have been
/// searched so an ABI-incompatible hit early on cannot shadow a usable
/// library found later. Only regular files count: a FIFO or device at a
/// candidate path could block on open.
async fn resolve_soname(
  soname : String,
  search_dirs : Array[String],
  cache : Map[String, Array[String]],
  dirs : Array[String],
  host : Int,
) -> String? {
  if soname.contains("/") {
    let usable = @fs.exists(soname) && @fs.kind(soname) is Regular
    return if usable { Some(soname) } else { None }
  }
  let first_unusable : Ref[String?] = { val: None, }
  let searched : Array[String] = []
  for dir in search_dirs {
    searched.push(dir + "/" + soname)
  }
  match pick_usable(searched, host, first_unusable) {
    Some(found) => return Some(found)
    None => ()
  }
  match cache.get(soname) {
    Some(candidates) =>
      match pick_usable(candidates, host, first_unusable) {
        Some(found) => return Some(found)
        None => ()
      }
    None => ()
  }
  let defaults : Array[String] = []
  for dir in dirs {
    defaults.push(dir + "/" + soname)
  }
  match pick_usable(defaults, host, first_unusable) {
    Some(found) => return Some(found)
    None => ()
  }
  // Every candidate in every tier was unusable for this host: report the
  // first so the caller can reject it as an unusable library.
  first_unusable.val
}

///|
/// Sonames the kernel itself provides, so no filesystem resolution is
/// needed: the vDSO family is mapped into every process by the loader.
fn kernel_object_sonames() -> Array[String] {
  ["linux-vdso.so.1", "linux-vdso32.so.1", "linux-gate.so.1"]
}

///|
/// The directory component of a path ("/a/b/c.so" -> "/a/b").
fn dirname_of(path : String) -> String {
  let parts = path.split("/").collect()
  if parts.length() <= 1 {
    return "."
  }
  let dir = parts[:parts.length() - 1].iter().join("/")
  if dir == "" {
    "/"
  } else {
    dir
  }
}

///|
/// Parsed runtime dependencies of a resolved provider library, or None
/// when the file cannot be read as ELF64. The regular-file check precedes
/// the read so an untrusted soname path can never block on a FIFO.
async fn library_deps(path : String) -> ElfDeps? {
  guard @fs.kind(path) is Regular else { return None }
  let bytes = @fs.read_file(path).binary() catch { _ => return None }
  parse_elf64_deps(bytes)
}

///|
/// The version names a library file defines in .gnu.version_d, or None
/// when the file cannot be read or parsed as ELF64. An empty result means
/// the library parses but defines no versions (for example a musl libc).
async fn library_defined_versions(path : String) -> Array[String]? {
  // An untrusted DT_NEEDED string can name a FIFO or device: refuse to
  // open anything but a regular file.
  guard @fs.kind(path) is Regular else { return None }
  let bytes = @fs.read_file(path).binary() catch { _ => return None }
  let deps = match parse_elf64_deps(bytes) {
    Some(value) => value
    None => return None
  }
  Some(deps.verdef)
}

///|
/// Walk the transitive DT_NEEDED closure of the root object's dependencies
/// breadth-first, resolving each object's own soname list with its own
/// RUNPATH/RPATH context (`$ORIGIN` is the directory of the object holding
/// the dependency, so a provider's private $ORIGIN neighbors are honored).
/// `visited` guards dependency cycles like libA -> libB -> libA. An
/// object whose needed soname cannot be located, resolves to a file the
/// host cannot load, or requires a symbol version its provider does not
/// define aborts the install — exactly the cases where the real loader
/// would refuse to start the process. `owner` in each queue entry is only
/// used to make failure messages name the object holding the dependency.
async fn check_library_closure(
  name : String,
  root : ElfDeps,
  root_dir : String,
  env_dirs : Array[String],
  cache : Map[String, Array[String]],
  dirs : Array[String],
  host : Int,
  lib_tokens : Array[String],
) -> Unit {
  let visited : Map[String, Bool] = Map([])
  // The loader's link map: every object already loaded under a soname
  // identity is reused for later lookups — ld.so does not search the
  // filesystem again when a transitive DT_NEEDED names a soname that an
  // earlier object already provided (e.g. the executable's own direct
  // dependency). Without this a provider's narrower search context
  // would report an already-loaded library as missing.
  let loaded : Map[String, String] = Map([])
  // Each entry carries the DT_RPATH directories inherited from the
  // ancestor chain: legacy RPATH propagates to indirect dependencies
  // (nearest ancestor's first), unlike DT_RUNPATH.
  let queue : Array[(String, String, ElfDeps, Array[String])] = [
    ("installed binary \{name}", root_dir, root, []),
  ]
  let mut cursor = 0
  while cursor < queue.length() {
    let (owner, objdir, objdeps, inherited) = queue[cursor]
    cursor = cursor + 1
    // This object's own DT_RPATH heads the RPATH tier, followed by the
    // ancestors'; the whole tier is searched before LD_LIBRARY_PATH.
    let rpath_tier : Array[String] = []
    if objdeps.rpath_first {
      for dir in expand_runpath(objdeps.runpath, objdir, lib_tokens) {
        rpath_tier.push(dir)
      }
    }
    for dir in inherited {
      rpath_tier.push(dir)
    }
    // DT_RUNPATH applies only to this object's own dependencies and is
    // searched after LD_LIBRARY_PATH.
    let runpath_dirs = if !objdeps.rpath_first {
      expand_runpath(objdeps.runpath, objdir, lib_tokens)
    } else {
      []
    }
    let search_dirs = library_search_dirs(rpath_tier, env_dirs, runpath_dirs)
    let resolved : Map[String, String] = Map([])
    let missing : Array[String] = []
    let unusable : Array[String] = []
    for soname in objdeps.needed {
      // Kernel-supplied objects have no file to check: the loader always
      // satisfies them (the vDSO is mapped into every process).
      if kernel_object_sonames().contains(soname) {
        continue
      }
      // Reuse an object the loader already mapped under this soname
      // before searching again — the loaded object wins even when this
      // object's own search context could not find it.
      let found = match loaded.get(soname) {
        Some(found) => Some(found)
        None => resolve_soname(soname, search_dirs, cache, dirs, host)
      }
      match found {
        None => missing.push(soname)
        Some(path) => {
          resolved[soname] = path
          loaded[soname] = path
          // Existence is not enough: the loader also refuses a provider
          // that is not a host-architecture ELF shared object.
          if !elf_file_usable(path, host) {
            unusable.push(soname)
          }
        }
      }
    }
    guard missing.is_empty() else {
      let list = missing.join(", ")
      fail(
        "\{owner} cannot run on this system: unresolved libraries \{list}. Build it from source instead, or pass --skip-compat-check to install anyway.",
      )
    }
    guard unusable.is_empty() else {
      let list = unusable.join(", ")
      fail(
        "\{owner} cannot run on this system: unusable libraries \{list} (not loadable ELF64 shared objects for this architecture). Build it from source instead, or pass --skip-compat-check to install anyway.",
      )
    }
    // Queue each resolved provider so its own DT_NEEDED chain is checked
    // too — a missing transitive library stops the real loader as well.
    for soname in objdeps.needed {
      match resolved.get(soname) {
        Some(found) =>
          if !visited.contains(found) {
            visited[found] = true
            match library_deps(found) {
              // Children inherit this object's complete RPATH tier,
              // which already ends with the ancestors' entries.
              Some(child) =>
                queue.push(
                  ("library \{found}", dirname_of(found), child, rpath_tier),
                )
              None =>
                fail(
                  "\{owner} cannot run on this system: library \{found} is not a parseable ELF64 object. Build it from source instead, or pass --skip-compat-check to install anyway.",
                )
            }
          }
        None => ()
      }
    }
    for requirement in objdeps.verneed {
      let (provider, version) = requirement
      let provider_path = match resolved.get(provider) {
        Some(found) => Some(found)
        None => resolve_soname(provider, search_dirs, cache, dirs, host)
      }
      match provider_path {
        None =>
          fail(
            "\{owner} cannot run on this system: it requires symbol version \{version} from \{provider}, which cannot be located. Build it from source instead, or pass --skip-compat-check to install anyway.",
          )
        Some(found) =>
          if !elf_file_usable(found, host) {
            fail(
              "\{owner} cannot run on this system: it requires symbol version \{version} from \{provider}, but \{found} is not a usable ELF shared object. Build it from source instead, or pass --skip-compat-check to install anyway.",
            )
          } else {
            match library_defined_versions(found) {
              Some(defined) =>
                if !defined.contains(version) {
                  fail(
                    "\{owner} cannot run on this system: it requires symbol version \{version} from \{provider}, which the installed \{found} does not provide. Build it from source instead, or pass --skip-compat-check to install anyway.",
                  )
                }
              // An unparseable provider is left to the runtime loader.
              None => ()
            }
            if !visited.contains(found) {
              visited[found] = true
              match library_deps(found) {
                Some(child) =>
                  queue.push(
                    ("library \{found}", dirname_of(found), child, rpath_tier),
                  )
                None => ()
              }
            }
          }
      }
    }
  }
}

///|
/// Reject a staged binary that cannot run on this host — inspected without
/// executing the downloaded file or running `ldd` on it, so hostile or
/// corrupted artifacts stay inert. A host-architecture ELF64 is rejected
/// when it is not an executable (e.g. a relocatable object), its program
/// headers are malformed, its PT_INTERP loader is absent or missing, a
/// DT_NEEDED library cannot be resolved through LD_LIBRARY_PATH and its
/// RUNPATH/RPATH, the ldconfig cache and the usual library directories
/// (checked transitively, since a provider's own missing dependency
/// stops the loader too), or a required symbol version (GLIBC_*,
/// GLIBCXX_*, ...) is not defined by the resolved provider library.
/// Other formats and foreign architectures are skipped — they may be
/// fetched on purpose for a different machine. `install_dir` is the
/// binary's final destination directory, used to expand `$ORIGIN`.
async fn verify_binary_compat(
  path : String,
  binary : Bytes,
  skip_compat_check : Bool,
  install_dir : String,
) -> Unit {
  if skip_compat_check {
    return
  }
  let machine = match elf_machine(binary) {
    Some(value) => value
    None => return
  }
  guard host_linux() else { return }
  let host = match host_machine() {
    Some(value) => value
    None => return
  }
  guard machine == host else { return }
  let name = path.split("/").last().unwrap_or(path)
  // e_type: only ET_EXEC (2) and ET_DYN (3) can be executed; a host-arch
  // ET_REL object file must not slip through as "unknown format".
  let etype = elf_u16le(binary, 16)
  guard etype == 2 || etype == 3 else {
    fail(
      "installed binary \{name} cannot run on this system: ELF type \{etype} is not executable. Build it from source instead, or pass --skip-compat-check to install anyway.",
    )
  }
  // Only ELF64 is parsed; other classes (e.g. a 32-bit binary) fall
  // through unverified rather than being rejected as malformed.
  guard binary[4].to_int() == 2 else { return }
  let deps = match parse_elf64_deps(binary) {
    Some(value) => value
    None =>
      fail(
        "installed binary \{name} cannot run on this system: malformed ELF64 program headers. Build it from source instead, or pass --skip-compat-check to install anyway.",
      )
  }
  match deps.interp {
    Some(interp) =>
      if interp != "" {
        // An existing path is not enough: the kernel refuses a PT_INTERP
        // that is not a regular executable host-architecture ELF loader.
        let usable = @fs.exists(interp) &&
          @fs.kind(interp) is Regular &&
          @fs.can_execute(interp) &&
          elf_file_usable(interp, host)
        if !usable {
          fail(
            "installed binary \{name} cannot run on this system: ELF interpreter \{interp} is missing or is not an executable ELF loader for this architecture. Build it from source instead, or pass --skip-compat-check to install anyway.",
          )
        }
      }
    None =>
      if !deps.needed.is_empty() {
        fail(
          "installed binary \{name} cannot run on this system: it needs shared libraries but has no ELF interpreter. Build it from source instead, or pass --skip-compat-check to install anyway.",
        )
      }
  }
  let env_dirs = ld_library_dirs(@env.get_env_var("LD_LIBRARY_PATH"))
  let cache = ldconfig_map()
  let dirs = library_dirs()
  let lib_tokens = lib_token_names(host)
  check_library_closure(
    name.to_owned(),
    deps,
    install_dir,
    env_dirs,
    cache,
    dirs,
    host,
    lib_tokens,
  )
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
  skip_compat_check : Bool,
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
      archive_path,
      item.format,
      plan.archive_candidates,
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
  verify_binary_compat(staging, binary, skip_compat_check, bin_dir)
  ownership_transferred = true
  { destination, staging, staging_dir, }
}

///|
pub async fn install_many(options : BatchOptions) -> Unit {
  install_many_using(options, Https)
}

///|
/// Parse the host libc from `ldd --version` output: "musl" on musl systems,
/// the dotted version on glibc systems, or None when it cannot be told.
fn parse_host_libc(output : String) -> String? {
  if output.contains("musl") {
    return Some("musl")
  }
  // GNU ldd prints e.g. "ldd (Ubuntu GLIBC 2.35-0ubuntu3.14) 2.35" and ends
  // the first line with the version number.
  match output.split("\n").iter().next() {
    None => None
    Some(first_line) => {
      let mut version : String? = None
      for token in first_line.split(" ") {
        let text = token.trim().to_owned()
        if text != "" && text[0] >= '0' && text[0] <= '9' && text.contains(".") {
          version = Some(text)
        }
      }
      version
    }
  }
}

///|
/// Compare dotted numeric versions componentwise: "2.9" < "2.35".
fn version_lt(left : String, right : String) -> Bool {
  let a = left.split(".").collect()
  let b = right.split(".").collect()
  let n = if a.length() > b.length() { a.length() } else { b.length() }
  for i = 0; i < n; i = i + 1 {
    let x = if i < a.length() { parse_digits(a[i]) } else { 0 }
    let y = if i < b.length() { parse_digits(b[i]) } else { 0 }
    if x != y {
      return x < y
    }
  }
  false
}

///|
fn parse_digits(text : StringView) -> Int {
  let mut value = 0
  for c in text {
    if c >= '0' && c <= '9' {
      value = value * 10 + (c.to_int() - '0'.to_int())
    } else {
      break
    }
  }
  value
}

///|
/// Fail before downloading when the publisher declares a glibc minimum that
/// the host cannot satisfy (musl hosts and older glibc). Only applies when
/// the install targets a Linux binary for this host's own architecture —
/// a cross-architecture fetch is left to the post-download ELF check,
/// which inspects the real binary.
async fn check_declared_glibc(
  glibc_min : String?,
  target : String,
  binary : String,
  skip_compat_check : Bool,
) -> Unit {
  if skip_compat_check {
    return
  }
  let min = match glibc_min {
    Some(value) => value
    None => return
  }
  let target_machine = match target {
    "linux-x86_64" => 62
    "linux-aarch64" => 183
    _ => return
  }
  guard host_linux() else { return }
  let host = match host_machine() {
    Some(value) => value
    None => return
  }
  guard host == target_machine else { return }
  match host_libc() {
    Some("musl") =>
      fail(
        "installed binary \{binary} requires glibc >= \{min} but this system uses musl libc. Build it from source instead, or pass --skip-compat-check to install anyway.",
      )
    Some(version) =>
      if version_lt(version, min) {
        fail(
          "installed binary \{binary} requires glibc >= \{min} but this system has glibc \{version}. Build it from source instead, or pass --skip-compat-check to install anyway.",
        )
      }
    None => ()
  }
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
    check_declared_glibc(
      plan.glibc_min,
      plan.target,
      plan.install.binary,
      options.skip_compat_check,
    )
  }
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
      options.skip_compat_check,
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
    skip_compat_check: config.skip_compat_check,
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
  verify_binary_compat(staging, content, false, bin_dir)
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
    println("moon-binstall 0.1.6")
    return 0
  }
  let config = parse_batch_options(argv)
  install_many(config)
  0
}
