///|
let max_installed_binary_bytes : Int = 134217728

///|
let max_archive_listing_bytes : Int = 16777216

///|
let max_archive_entries : Int = 100000

///|
/// Read the selected executable's bytes without unpacking archive paths onto
/// disk. Both tar and zip entries are preflighted before their content is read.
pub async fn read_artifact_binary(
  archive_path : String,
  format : String,
  member_path : String?,
) -> Bytes {
  read_artifact_binary_with_limit(
    archive_path, format, member_path, max_installed_binary_bytes,
  )
}

///|
/// Keep decompression bounded while the helper process produces stdout,
/// before its output is materialized in memory.
pub async fn read_artifact_binary_with_limit(
  archive_path : String,
  format : String,
  member_path : String?,
  max_binary_bytes : Int,
) -> Bytes {
  validate_archive_format(format)
  guard max_binary_bytes > 0 else { fail("binary size limit must be positive") }
  if format == "bin" {
    let bytes = @fs.read_file(archive_path).binary()
    guard bytes.length() > 0 && bytes.length() <= max_binary_bytes else {
      fail("downloaded binary has an invalid size")
    }
    return bytes
  }
  let selected_path = match member_path {
    Some(path) => path
    None =>
      fail(
        "archive packages require bin-path in moon-binstall.json or --bin-path",
      )
  }
  validate_member_path(selected_path)
  let bytes = match format {
    "tar" | "tgz" | "tar.gz" | "tbz2" | "tar.bz2" | "txz" | "tar.xz" |
    "tzstd" | "tar.zst" | "tar.zstd" =>
      read_tar_member(archive_path, selected_path, max_binary_bytes, format)
    "zip" => read_zip_member(archive_path, selected_path, max_binary_bytes)
    _ => fail("unsupported package format")
  }
  guard bytes.length() > 0 && bytes.length() <= max_binary_bytes else {
    fail("archive member has an invalid size")
  }
  bytes
}

///|
/// Discover an archive member from ordered, exact paths. Every archive entry
/// is preflighted before the first candidate is accepted.
pub async fn read_artifact_binary_from_candidates(
  archive_path : String,
  format : String,
  candidates : Array[String],
) -> Bytes {
  read_artifact_binary_from_candidates_with_limit(
    archive_path, format, candidates, max_installed_binary_bytes,
  )
}

///|
pub async fn read_artifact_binary_from_candidates_with_limit(
  archive_path : String,
  format : String,
  candidates : Array[String],
  max_binary_bytes : Int,
) -> Bytes {
  validate_archive_format(format)
  guard max_binary_bytes > 0 else { fail("binary size limit must be positive") }
  guard candidates.length() > 0 else {
    fail("archive member discovery has no candidates")
  }
  let seen_candidates : Array[String] = []
  for candidate in candidates {
    validate_member_path(candidate)
    guard !seen_candidates.contains(candidate) else {
      fail("duplicate archive member discovery candidate: \{candidate}")
    }
    seen_candidates.push(candidate)
  }
  if format == "bin" {
    return read_artifact_binary_with_limit(
      archive_path, format, None, max_binary_bytes,
    )
  }
  let bytes = match format {
    "tar" | "tgz" | "tar.gz" | "tbz2" | "tar.bz2" | "txz" | "tar.xz" |
    "tzstd" | "tar.zst" | "tar.zstd" =>
      read_tar_members_optional(archive_path, candidates, max_binary_bytes, format)
    "zip" =>
      read_zip_members_optional_with_limit(
        archive_path, candidates, max_binary_bytes,
      )
    _ => fail("unsupported archive format")
  }
  match bytes {
    Some(bytes) => {
      guard bytes.length() > 0 && bytes.length() <= max_binary_bytes else {
        fail("archive member has an invalid size")
      }
      bytes
    }
    None => fail("archive does not contain any default binary member")
  }
}

///|
async fn read_tar_member(
  archive_path : String,
  wanted : String,
  max_binary_bytes : Int,
  format : String,
) -> Bytes {
  match read_tar_members_optional(archive_path, [wanted], max_binary_bytes, format) {
    Some(bytes) => bytes
    None => fail("archive does not contain requested binary: \{wanted}")
  }
}

///|
async fn read_tar_members_optional(
  archive_path : String,
  wanted_paths : Array[String],
  max_binary_bytes : Int,
  format : String,
) -> Bytes? {
  validate_tar_format_signature(archive_path, format)
  let (list_code, list_data) = run_bounded(
    "tar",
    ["-t", "-f", archive_path],
    max_archive_listing_bytes,
  )
  guard list_code == 0 else { fail("tar could not list the package archive") }
  let names = nonempty_lines(@utf8.decode(list_data))
  let (verbose_code, verbose_data) = run_bounded(
    "tar",
    ["-t", "-v", "-f", archive_path],
    max_archive_listing_bytes,
  )
  guard verbose_code == 0 else {
    fail("tar could not inspect the package archive")
  }
  let details = nonempty_lines(@utf8.decode(verbose_data))
  guard details.length() == names.length() else {
    fail("tar archive has ambiguous member names")
  }
  let seen : Array[String] = []
  let selected : Array[String?] = []
  for _ in wanted_paths {
    selected.push(None)
  }
  for i = 0; i < names.length(); i = i + 1 {
    let raw_name = names[i]
    let normalized = validate_archive_entry(raw_name)
    guard seen.length() < max_archive_entries else {
      fail("archive contains too many entries")
    }
    seen.push(normalized)
    let detail = details[i]
    let fields = whitespace_fields(detail)
    guard fields.length() >= 2 else { fail("invalid tar member metadata") }
    let mode = fields[0]
    let kind = first_char(mode)
    let last_field = fields[fields.length() - 1]
    guard last_field == raw_name else {
      fail(
        "tar member names with whitespace or control characters are unsupported",
      )
    }
    if kind == 'd' {
      if wanted_paths.contains(normalized) {
        fail("requested archive member is a directory")
      }
      continue
    }
    guard kind == '-' else {
      fail("tar archive contains a link or special file")
    }
    for candidate_index = 0; candidate_index < wanted_paths.length(); candidate_index = candidate_index + 1 {
      if normalized == wanted_paths[candidate_index] {
        guard selected[candidate_index] is None else {
          fail("archive contains duplicate executable members")
        }
        selected[candidate_index] = Some(raw_name)
      }
    }
  }
  validate_unique_archive_paths(seen)
  let mut selected_name : String? = None
  for candidate_index = 0; candidate_index < selected.length(); candidate_index = candidate_index + 1 {
    if selected_name is None {
      selected_name = selected[candidate_index]
    }
  }
  let selected_name = match selected_name {
    Some(name) => name
    None => return None
  }
  let (code, output) = run_bounded(
    "tar",
    ["-xO", "-f", archive_path, "--", selected_name],
    max_binary_bytes,
  )
  guard code == 0 else { fail("tar could not read the selected binary") }
  Some(output)
}

///|
/// GNU tar and bsdtar detect compression by archive magic when reading. Check
/// that the declared package format agrees with that magic before invoking tar.
async fn validate_tar_format_signature(
  archive_path : String,
  format : String,
) -> Unit {
  if format == "tar" {
    validate_plain_tar_header(archive_path)
    return
  }
  let signature = match format {
    "tgz" | "tar.gz" => "1f 8b"
    "tbz2" | "tar.bz2" => "42 5a 68"
    "txz" | "tar.xz" => "fd 37 7a 58 5a 00"
    "tzstd" | "tar.zst" | "tar.zstd" => "28 b5 2f fd"
    _ => fail("unsupported tar package format: \{format}")
  }
  let (code, output) = run_bounded(
    "od",
    ["-An", "-tx1", "-N", "6", archive_path],
    64,
  )
  guard code == 0 else { fail("could not inspect tar archive header") }
  let header = @utf8.decode(output).trim().to_owned()
  guard header.has_prefix(signature) else {
    fail("tar archive compression does not match the declared format")
  }
}

///|
/// Verify a plausible first tar header after excluding common compressed and
/// container signatures, whose metadata can also satisfy the tar checksum.
async fn validate_plain_tar_header(archive_path : String) -> Unit {
  reject_known_non_tar_signature(archive_path)
  let (code, output) = run_bounded(
    "od",
    ["-An", "-v", "-tu1", "-N", "512", archive_path],
    4096,
  )
  guard code == 0 else { fail("could not inspect plain tar archive header") }
  let text = @utf8.decode(output).split("\n").collect().join(" ")
  let fields = whitespace_fields(text)
  guard fields.length() == 512 else {
    fail("plain tar archive has an incomplete header")
  }
  let header : Array[Int] = []
  for field in fields {
    header.push(parse_decimal_byte(field))
  }
  let mut expected_checksum = 0
  let mut checksum_has_digits = false
  for i = 148; i < 156; i = i + 1 {
    let byte = header[i]
    if byte == 0 || byte == 32 {
      continue
    }
    guard byte >= 48 && byte <= 55 else {
      fail("plain tar archive has an invalid checksum field")
    }
    expected_checksum = expected_checksum * 8 + byte - 48
    checksum_has_digits = true
  }
  guard checksum_has_digits else {
    fail("plain tar archive has an empty checksum field")
  }
  let mut actual_checksum = 0
  for i = 0; i < header.length(); i = i + 1 {
    let byte = if i >= 148 && i < 156 {
      32
    } else {
      header[i]
    }
    actual_checksum = actual_checksum + byte
  }
  guard actual_checksum == expected_checksum else {
    fail("plain tar archive has an invalid header checksum")
  }
}

///|
/// GNU tar and bsdtar can auto-detect compressed streams and other containers.
/// Reject their recognizable magic before checking a declared plain tar.
async fn reject_known_non_tar_signature(archive_path : String) -> Unit {
  let (code, output) = run_bounded(
    "od",
    ["-An", "-tx1", "-N", "16", archive_path],
    128,
  )
  guard code == 0 else { fail("could not inspect plain tar archive signature") }
  let header = @utf8.decode(output).trim().to_owned()
  let known_signatures = [
    "1f 8b", // gzip
    "fd 37 7a 58 5a 00", // xz
    "28 b5 2f fd", // zstd
    "1f 9d", // compress
    "89 4c 5a 4f", // lzop
    "04 22 4d 18", // lz4 frame
    "02 21 4c 18", // legacy lz4
    "50 4b 03 04", // ZIP local file
    "50 4b 05 06", // empty ZIP
    "50 4b 06 06", // ZIP64 end record
    "50 4b 06 07", // ZIP64 locator
    "50 4b 07 08", // spanned ZIP
    "37 7a bc af 27 1c", // 7-Zip
    "52 61 72 21 1a 07", // RAR
    "21 3c 61 72 63 68 3e 0a", // ar
    "ed ab ee db", // RPM
  ]
  for signature in known_signatures {
    guard !header.has_prefix(signature) else {
      fail("plain tar archive has a compressed or non-tar signature")
    }
  }
  let bytes = whitespace_fields(header)
  let skippable_zstd_magic = [
    "50", "51", "52", "53", "54", "55", "56", "57",
    "58", "59", "5a", "5b", "5c", "5d", "5e", "5f",
  ]
  if bytes.length() >= 4 &&
    skippable_zstd_magic.contains(bytes[0]) &&
    bytes[1] == "2a" &&
    bytes[2] == "4d" &&
    bytes[3] == "18" {
    fail("plain tar archive has a compressed or non-tar signature")
  }
}

///|
fn parse_decimal_byte(value : String) -> Int raise {
  guard value != "" else { fail("invalid byte value in tar header") }
  let mut result = 0
  for c in value {
    let digit = match c {
      '0' => 0
      '1' => 1
      '2' => 2
      '3' => 3
      '4' => 4
      '5' => 5
      '6' => 6
      '7' => 7
      '8' => 8
      '9' => 9
      _ => fail("invalid byte value in tar header")
    }
    result = result * 10 + digit
  }
  guard result <= 255 else { fail("invalid byte value in tar header") }
  result
}

///|
async fn read_zip_member(
  archive_path : String,
  wanted : String,
  max_binary_bytes : Int,
) -> Bytes {
  match
    read_zip_member_optional_with_limit(archive_path, wanted, max_binary_bytes) {
    Some(bytes) => bytes
    None => fail("archive does not contain requested binary: \{wanted}")
  }
}

///|
pub async fn read_zip_member_optional(
  archive_path : String,
  wanted : String,
) -> Bytes? {
  read_zip_member_optional_with_limit(
    archive_path, wanted, max_installed_binary_bytes,
  )
}

///|
pub async fn read_zip_member_optional_with_limit(
  archive_path : String,
  wanted : String,
  max_member_bytes : Int,
) -> Bytes? {
  read_zip_members_optional_with_limit(
    archive_path, [wanted], max_member_bytes,
  )
}

///|
async fn read_zip_members_optional_with_limit(
  archive_path : String,
  wanted_paths : Array[String],
  max_member_bytes : Int,
) -> Bytes? {
  guard max_member_bytes > 0 else { fail("binary size limit must be positive") }
  for wanted in wanted_paths {
    validate_member_path(wanted)
  }
  let (list_code, list_data) = run_bounded(
    "zipinfo",
    ["-1", archive_path],
    max_archive_listing_bytes,
  )
  guard list_code == 0 else {
    fail("zipinfo could not list the package archive")
  }
  let names = nonempty_lines(@utf8.decode(list_data))
  let (verbose_code, verbose_data) = run_bounded(
    "zipinfo",
    ["-l", archive_path],
    max_archive_listing_bytes,
  )
  guard verbose_code == 0 else {
    fail("zipinfo could not inspect the package archive")
  }
  let details = zip_detail_lines(@utf8.decode(verbose_data))
  guard details.length() == names.length() else {
    fail("zip archive has ambiguous member names")
  }
  let seen : Array[String] = []
  let selected : Array[String?] = []
  for _ in wanted_paths {
    selected.push(None)
  }
  for i = 0; i < names.length(); i = i + 1 {
    let raw_name = names[i]
    let normalized = validate_archive_entry(raw_name)
    guard seen.length() < max_archive_entries else {
      fail("archive contains too many entries")
    }
    seen.push(normalized)
    let fields = whitespace_fields(details[i])
    guard fields.length() >= 2 else { fail("invalid zip member metadata") }
    let mode = fields[0]
    let kind = first_char(mode)
    let last_field = fields[fields.length() - 1]
    guard last_field == raw_name else {
      fail(
        "zip member names with whitespace or control characters are unsupported",
      )
    }
    if kind == 'd' || (kind == '?' && raw_name.has_suffix("/")) {
      if wanted_paths.contains(normalized) {
        fail("requested archive member is a directory")
      }
      continue
    }
    guard kind == '-' || kind == '?' else {
      fail("zip archive contains a link or special file")
    }
    for candidate_index = 0; candidate_index < wanted_paths.length(); candidate_index = candidate_index + 1 {
      if normalized == wanted_paths[candidate_index] {
        guard selected[candidate_index] is None else {
          fail("archive contains duplicate executable members")
        }
        selected[candidate_index] = Some(raw_name)
      }
    }
  }
  validate_unique_archive_paths(seen)
  let mut selected_name : String? = None
  for candidate_index = 0; candidate_index < selected.length(); candidate_index = candidate_index + 1 {
    if selected_name is None {
      selected_name = selected[candidate_index]
    }
  }
  let selected_name = match selected_name {
    Some(name) => name
    None => return None
  }
  let (code, output) = run_bounded(
    "unzip",
    ["-p", archive_path, selected_name],
    max_member_bytes,
  )
  guard code == 0 else { fail("unzip could not read the selected binary") }
  Some(output)
}

///|
async fn run_bounded(
  program : String,
  args : Array[String],
  max_output_bytes : Int,
) -> (Int, Bytes) {
  let output = @shell.Cmd(program, args).output(
    timeout_ms=300000,
    max_output_bytes~,
  )
  (output.exit_code(), output.stdout_bytes())
}

///|
/// Sorting makes duplicate detection O(n log n) while preserving fail-closed
/// handling for every path, including entries other than the selected binary.
fn validate_unique_archive_paths(paths : Array[String]) -> Unit raise {
  paths.sort()
  for i = 1; i < paths.length(); i = i + 1 {
    guard paths[i - 1] != paths[i] else {
      fail("archive contains duplicate member path: \{paths[i]}")
    }
  }
}

///|
fn nonempty_lines(text : String) -> Array[String] {
  let lines = text.split("\n").collect()
  let result : Array[String] = []
  for line in lines {
    if line != "" {
      let clean = if line.has_suffix("\r") {
        line[:line.length() - 1].to_owned()
      } else {
        line.to_owned()
      }
      if clean != "" {
        result.push(clean)
      }
    }
  }
  result
}

///|
fn zip_detail_lines(text : String) -> Array[String] {
  let lines = nonempty_lines(text)
  let result : Array[String] = []
  for line in lines {
    let fields = whitespace_fields(line)
    if fields.length() > 1 {
      let kind = first_char(fields[0])
      if kind == '-' ||
        kind == '?' ||
        kind == 'd' ||
        kind == 'l' ||
        kind == 'b' ||
        kind == 'c' ||
        kind == 'p' {
        result.push(line)
      }
    }
  }
  result
}

///|
fn whitespace_fields(line : String) -> Array[String] {
  let result : Array[String] = []
  let fields = line.split(" ").collect()
  for field in fields {
    if field != "" {
      result.push(field.to_owned())
    }
  }
  result
}

///|
fn first_char(value : String) -> Char {
  for c in value {
    return c
  }
  ' '
}

///|
fn validate_archive_entry(raw_name : String) -> String raise {
  guard raw_name != "" && !raw_name.has_prefix("/") && !raw_name.contains("\\") else {
    fail("archive contains an absolute or invalid member path")
  }
  let is_directory = raw_name.has_suffix("/")
  let mut normalized = raw_name
  while normalized.has_prefix("./") {
    normalized = normalized[2:].to_owned()
  }
  if is_directory && normalized.has_suffix("/") {
    normalized = normalized[:normalized.length() - 1].to_owned()
  }
  if normalized == "" {
    guard is_directory else { fail("archive contains an empty member path") }
    return ""
  }
  let parts = normalized.split("/").collect()
  for part in parts {
    guard part != "" && part != "." && part != ".." &&
      !part.has_prefix("-") else {
      fail("archive contains a traversing or option-like member path")
    }
    for c in part {
      guard (c >= 'a' && c <= 'z') ||
        (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') ||
        c == '-' ||
        c == '_' ||
        c == '.' ||
        c == '+' else {
        fail("archive contains an unsupported member name")
      }
    }
  }
  normalized
}
