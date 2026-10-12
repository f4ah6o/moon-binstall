///|
/// An install receipt records what moon-binstall placed at a destination:
/// the coordinate and source it came from, the package/binary identity, the
/// selected tag, and two digests kept strictly separate (issue 0001).
/// `asset_digest` hashes the downloaded release asset (often a zip/tar
/// archive) and is compared to the next candidate's declared digest so an
/// identical release skips without downloading. `binary_digest` hashes the
/// extracted executable actually written and is compared to the file's
/// current content — a receipt alone never trusts a file.
pub struct InstallReceipt {
  coordinate : String
  source : String
  repository : String
  package_key : String
  binary : String
  target : String
  tag : String
  asset_digest : String
  binary_digest : String
  destination : String
}

///|
/// Receipts live beside the managed binaries in a dot directory so PATH
/// scans never pick them up.
pub fn receipt_path(bin_dir : String, binary : String) -> String {
  bin_dir + "/.moon-binstall-receipts/" + binary + ".json"
}

///|
/// Refuse to trust receipt paths that traverse a symlinked metadata directory
/// or use a non-regular receipt entry. This is checked again immediately
/// before a rename, not just during the install decision.
async fn validate_receipt_location(path : String) -> Unit {
  let dir = parent_dir(path)
  match path_kind_no_follow(dir) {
    Some(Directory) | None => ()
    Some(_) =>
      abort_install(
        Filesystem, "check the receipt directory", dir,
        "receipt directory is not a real directory (symlinks are not allowed)",
        action="remove the unsafe receipt directory and retry",
      )
  }
  match path_kind_no_follow(path) {
    Some(Regular) | None => ()
    Some(_) =>
      abort_install(
        Filesystem, "check the receipt file", path,
        "receipt entry is not a regular file (symlinks are not allowed)",
        action="remove the unsafe receipt entry and retry",
      )
  }
}

///|
/// Create a private receipt directory and write a new regular file before
/// atomically renaming it. Do not open an existing receipt for truncation:
/// that would follow a malicious symlink and overwrite its target.
async fn write_receipt(receipt : InstallReceipt) -> Unit {
  let path = receipt_path(
    parent_dir(receipt.destination),
    receipt.binary,
  )
  validate_receipt_location(path)
  let dir = parent_dir(path)
  match path_kind_no_follow(dir) {
    Some(Directory) => ()
    None => @fs.mkdir(dir, permission=0o700, allow_exist=false)
    Some(_) =>
      abort_install(
        Filesystem, "check the receipt directory", dir,
        "receipt directory must not be a symlink or non-directory",
      )
  }
  validate_receipt_location(path)
  let json : Json = {
    "version": 1,
    "coordinate": receipt.coordinate,
    "source": receipt.source,
    "repository": receipt.repository,
    "package": receipt.package_key,
    "binary": receipt.binary,
    "target": receipt.target,
    "tag": receipt.tag,
    "asset_digest": receipt.asset_digest,
    "binary_digest": receipt.binary_digest,
    "destination": receipt.destination,
  }
  let staging_dir = create_staging_directory_at(dir, 0, "receipt")
  defer (@fs.rmdir(staging_dir, recursive=true) catch { _ => () })
  let staging = staging_dir + "/" + receipt.binary + ".json"
  @fs.write_file(
    staging,
    json.stringify() + "\n",
    create_mode=CreateNew,
    permission=0o600,
  )
  validate_receipt_location(path)
  @fs.rename(staging, path, replace=true)
}

///|
/// Directory part of an absolute path, without the trailing element.
fn parent_dir(path : String) -> String {
  let mut index = path.length() - 1
  while index > 0 && path[index] != '/' {
    index = index - 1
  }
  if index == 0 {
    "/"
  } else {
    path[:index].to_owned()
  }
}

///|
/// Read a receipt for the binary at `destination`; None when absent or
/// malformed. Malformed receipts are treated like missing ones so a bad
/// file can never silently authorize an update.
async fn read_receipt_file(path : String) -> InstallReceipt? {
  // Do not read receipts through symlinks even if the link target is valid JSON.
  guard path_kind_no_follow(parent_dir(path)) is Some(Directory) else {
    return None
  }
  guard path_kind_no_follow(path) is Some(Regular) else {
    return None
  }
  let text = @fs.read_file(path).text() catch { _ => return None }
  let json = @json.parse(text) catch { _ => return None }
  match json {
    {
      "coordinate": String(coordinate),
      "source": String(source),
      "repository": String(repository),
      "package": String(package_key),
      "binary": String(binary),
      "target": String(target),
      "tag": String(tag),
      "asset_digest": String(asset_digest),
      "binary_digest": String(binary_digest),
      "destination": String(destination),
      ..
    } =>
      Some(
        InstallReceipt::{
          coordinate,
          source,
          repository,
          package_key,
          binary,
          target,
          tag,
          asset_digest,
          binary_digest,
          destination,
        },
      )
    _ => None
  }
}

///|
/// Parse a semver-ish version: optional leading 'v', exactly three numeric
/// components. Anything else is incomparable — never guessed.
fn parse_semver(value : String) -> (Int, Int, Int)? {
  let body = if value.has_prefix("v") || value.has_prefix("V") {
    value[1:].to_owned()
  } else {
    value
  }
  let parts = body.split(".").collect()
  guard parts.length() == 3 else { return None }
  let numbers : Array[Int] = []
  for part in parts {
    if part == "" || part.length() > 9 {
      return None
    }
    let mut value = 0
    for c in part {
      guard c >= '0' && c <= '9' else { return None }
      value = value * 10 + (c.to_int() - '0'.to_int())
    }
    numbers.push(value)
  }
  Some((numbers[0], numbers[1], numbers[2]))
}

///|
/// Strict semver ordering: -1 when a < b, 0 when equal, 1 when a > b, None
/// when either side cannot be parsed. Used for update decisions only.
pub fn semver_compare(a : String, b : String) -> Int? {
  match (parse_semver(a), parse_semver(b)) {
    (Some((amaj, amin, apat)), Some((bmaj, bmin, bpat))) => {
      if amaj != bmaj {
        return Some(if amaj < bmaj { -1 } else { 1 })
      }
      if amin != bmin {
        return Some(if amin < bmin { -1 } else { 1 })
      }
      if apat != bpat {
        return Some(if apat < bpat { -1 } else { 1 })
      }
      Some(0)
    }
    _ => None
  }
}
