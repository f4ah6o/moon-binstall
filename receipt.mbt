///|
/// An install receipt records what moon-binstall placed at a destination:
/// the coordinate and source it came from, the package/binary identity, the
/// selected tag and the verified digest of the installed content. Receipts
/// let a later run tell its own managed files from foreign or modified ones
/// (issue 0001). A receipt alone never trusts a file: the stored digest is
/// always compared to the file's current content.
pub struct InstallReceipt {
  coordinate : String
  source : String
  repository : String
  package_key : String
  binary : String
  target : String
  tag : String
  digest : String
  destination : String
}

///|
/// Receipts live beside the managed binaries in a dot directory so PATH
/// scans never pick them up.
pub fn receipt_path(bin_dir : String, binary : String) -> String {
  bin_dir + "/.moon-binstall-receipts/" + binary + ".json"
}

///|
async fn write_receipt(receipt : InstallReceipt) -> Unit {
  let path = receipt_path(
    parent_dir(receipt.destination),
    receipt.binary,
  )
  @fs.mkdir(parent_dir(path), recursive=true, allow_exist=true)
  let json : Json = {
    "version": 1,
    "coordinate": receipt.coordinate,
    "source": receipt.source,
    "repository": receipt.repository,
    "package": receipt.package_key,
    "binary": receipt.binary,
    "target": receipt.target,
    "tag": receipt.tag,
    "digest": receipt.digest,
    "destination": receipt.destination,
  }
  @fs.write_file(
    path,
    json.stringify() + "\n",
    create_mode=CreateOrTruncate,
  )
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
      "digest": String(digest),
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
          digest,
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
