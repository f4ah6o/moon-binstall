///|
// These are the coordinate safety grammars, not SemVer or GitHub account
// naming rules. Enumerated alphabets deliberately avoid the implementation's
// character-range comparisons. No production validator is used by the oracle.
let qc_id_alphabet : String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."

///|
let qc_tag_alphabet : String = qc_id_alphabet + "+"

///|
let qc_version_alphabet : String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.+"

///|
fn qc_in_alphabet(value : String, alphabet : String) -> Bool {
  value.iter().all(c => alphabet.contains(c.to_string()))
}

///|
fn qc_id_model(value : String) -> Bool {
  !["", ".", ".."].contains(value) && qc_in_alphabet(value, qc_id_alphabet)
}

///|
fn qc_tag_model(value : String) -> Bool {
  value != "" &&
  value.iter().next() != Some('.') &&
  qc_in_alphabet(value, qc_tag_alphabet)
}

///|
fn qc_version_model(value : String) -> Bool {
  value != "" &&
  value.iter().next() != Some('.') &&
  value.rev().iter().next() != Some('.') &&
  qc_in_alphabet(value, qc_version_alphabet)
}

///|
priv struct QcToken(String) derive(Debug)

///|
fn qc_alphabet_generator(alphabet : String) -> @quickcheck.Generator[String] {
  let chars = alphabet.iter().map(c => c.to_string()).collect()
  @quickcheck.sized(size => {
    @quickcheck.int_range(0, size.max(0)).flat_map(n => {
      @quickcheck.elements(chars).array_with_size(n).map(xs => xs.join(""))
    })
  })
}

///|
impl @quickcheck.Arbitrary for QcToken with fn arbitrary(size, state) {
  let boundaries = [
    "", ".", "..", "...", "a", "z", "A", "Z", "0", "9", "-", "_", "+", ".a", "a.",
    "a_b", ".mbt", "tool.mbt", "é", "😀", "\u{0}", "/", "@", "-2147483648", "2147483647",
  ]
  QcToken(
    @quickcheck.frequency([
      (3, @quickcheck.elements(boundaries)),
      (3, qc_alphabet_generator(qc_tag_alphabet)),
      (2, @quickcheck.spawn()),
    ]).run(size, state),
  )
}

///|
impl @quickcheck.Shrink for QcToken with fn shrink(token) {
  @quickcheck.Shrink::shrink(token.0).map(s => QcToken(s))
}

///|
priv struct QcCoordinate {
  module_path : String
  input : String
} derive(Debug)

///|
impl @quickcheck.Arbitrary for QcCoordinate with fn arbitrary(size, state) {
  let token = () => (@quickcheck.Arbitrary::arbitrary(size, state) : QcToken).0
  let valid = () => qc_alphabet_generator(qc_id_alphabet).run(size, state)
  let path = (count : Int) => {
    Array::makei(count, _ => {
      if @quickcheck.gen(state~) {
        token()
      } else {
        valid()
      }
    }).join("/")
  }
  let mut input = path(@quickcheck.int_range(0, 6).run(size, state))
  if @quickcheck.gen(state~) {
    input += "@" + token()
  }
  if @quickcheck.int_range(0, 9).run(size, state) == 0 {
    input += "@" + token()
  }
  { module_path: path(@quickcheck.int_range(0, 3).run(size, state)), input, }
}

///|
impl @quickcheck.Shrink for QcCoordinate with fn shrink(value) {
  @quickcheck.Shrink::shrink((value.module_path, value.input)).map(pair => QcCoordinate::{
    module_path: pair.0,
    input: pair.1,
  })
}

///|
priv struct QcPath {
  segments : Array[String]
  version : String?
}

///|
// A character scanner for path[/path]*[@version]. This oracle does not use
// split, parse_package, parse_coordinate or any production safety predicate.
fn qc_scan(input : String) -> QcPath? {
  let segments : Array[String] = []
  let buffer = StringBuilder()
  let mut in_version = false
  for c in input {
    match c {
      '@' => {
        if in_version {
          return None
        }
        segments.push(buffer.to_string())
        buffer.reset()
        in_version = true
      }
      '/' if !in_version => {
        segments.push(buffer.to_string())
        buffer.reset()
      }
      _ => buffer.write_char(c)
    }
  }
  let version = if in_version {
    Some(buffer.to_string())
  } else {
    segments.push(buffer.to_string())
    None
  }
  Some({ segments, version, })
}

///|
fn qc_binary(leaf : String) -> String {
  match leaf.rev().strip_prefix("tbm.") {
    Some(rest) => rest.to_owned().rev()
    None => leaf
  }
}

///|
fn qc_expected_path(input : String, github~ : Bool) -> QcPath? {
  guard qc_scan(input) is Some(path) else { None }
  guard (!github || path.segments.length() == 2) &&
    path.segments.iter().all(qc_id_model) else {
    None
  }
  guard path.version is None ||
    (
      path.version is Some(v) &&
      (if github { qc_tag_model(v) } else { qc_version_model(v) })
    ) else {
    None
  }
  guard qc_binary(path.segments[path.segments.length() - 1]) != "" else { None }
  Some(path)
}

///|
fn qc_package_matches(input : String) -> Bool {
  let expected = qc_expected_path(input, github=true)
  try parse_package(input) catch {
    InstallError(stage~, ..) => expected is None && stage is Coordinate
    _ => false
  } noraise {
    pkg =>
      match expected {
        Some(path) =>
          pkg.owner == path.segments[0] &&
          pkg.repo == path.segments[1] &&
          pkg.binary == qc_binary(path.segments[1]) &&
          pkg.version == path.version
        None => false
      }
  }
}

///|
fn qc_coordinate_matches(input : String) -> Bool {
  let github = match qc_scan(input) {
    Some(path) => path.segments.length() < 3
    None => true
  }
  let expected = qc_expected_path(input, github~)
  try parse_coordinate(input) catch {
    InstallError(stage~, ..) => expected is None && stage is Coordinate
    _ => false
  } noraise {
    coordinate =>
      match (coordinate, expected) {
        (GitHub(pkg), Some(path)) =>
          github &&
          pkg.owner == path.segments[0] &&
          pkg.repo == path.segments[1] &&
          pkg.binary == qc_binary(path.segments[1]) &&
          pkg.version == path.version
        (Mooncakes(pkg), Some(path)) =>
          !github &&
          pkg.module_path == path.segments[:2].to_owned().join("/") &&
          pkg.package_path == path.segments[2:].to_owned().join("/") &&
          pkg.binary == qc_binary(path.segments[path.segments.length() - 1]) &&
          pkg.version == path.version
        _ => false
      }
  }
}

///|
fn qc_module_matches(module_path : String, input : String) -> Bool {
  let module_valid = match qc_scan(module_path) {
    Some(path) =>
      path.version is None &&
      path.segments.length() == 2 &&
      path.segments.iter().all(qc_id_model)
    None => false
  }
  let expected = if module_valid {
    qc_expected_path(input, github=false)
  } else {
    None
  }
  try parse_module_package(module_path, input) catch {
    InstallError(stage~, ..) => expected is None && stage is Coordinate
    _ => false
  } noraise {
    pkg =>
      match expected {
        Some(path) =>
          pkg.module_path == module_path &&
          pkg.package_path == path.segments.join("/") &&
          pkg.binary == qc_binary(path.segments[path.segments.length() - 1]) &&
          pkg.version == path.version
        None => false
      }
  }
}

///|
test "prop coordinate validators match enumerated safety grammars" {
  @quickcheck.check(
    (token : QcToken) => {
      valid_id(token.0) == qc_id_model(token.0) &&
      valid_tag(token.0) == qc_tag_model(token.0) &&
      valid_registry_version(token.0) == qc_version_model(token.0)
    },
    count=1000,
    max_size=50,
    max_shrinks=1000,
    seed=1777,
  )
}

///|
test "prop coordinate parsers match character scanner and safety grammars" {
  @quickcheck.check(
    (value : QcCoordinate) => {
      qc_package_matches(value.input) &&
      qc_coordinate_matches(value.input) &&
      qc_module_matches(value.module_path, value.input)
    },
    count=1000,
    max_size=50,
    max_shrinks=1000,
    seed=1777,
  )
}

///|
test "coordinate grammar boundaries include ASCII equality Unicode and numeric text" {
  for code in 0..<128 {
    let token = code.to_char().unwrap().to_string()
    assert_eq(valid_id(token), qc_id_model(token))
    assert_eq(valid_tag(token), qc_tag_model(token))
    assert_eq(valid_registry_version(token), qc_version_model(token))
  }
  for
    token in [
      "", ".", "..", "...", ".a", "a.", "_", "+", "é", "😀", "\u{d7ff}", "\u{e000}",
      "\u{10ffff}", "0", "-1", "2147483647", "-2147483648",
    ] {
    assert_eq(valid_id(token), qc_id_model(token))
    assert_eq(valid_tag(token), qc_tag_model(token))
    assert_eq(valid_registry_version(token), qc_version_model(token))
  }
  // Registry versions are a safety grammar, so '+' and '-' are accepted.
  assert_true(valid_registry_version("+"))
  assert_true(valid_registry_version("-"))
  assert_true(valid_id("..."))
  assert_true(valid_tag("a."))
  assert_true(!valid_registry_version("a."))
  assert_true(valid_tag("a_b"))
  assert_true(!valid_registry_version("a_b"))
}

///|
test "coordinate parser boundaries preserve fields and reject unsafe paths" {
  for
    input in [
      "", "/", "a/", "/b", "./b", "../b", ".../b", "a/.mbt", "a/a.mbt", "a/A.MBT",
      "a/b@", "a/b@.x", "a/b@x.", "a/b@a_b", "a/b@+", "a/b@0", "a/b@2147483647",
      "a/b@-2147483648", "a/b@v1@v2", "a/b/c", "a/b/c/d.mbt@1.0+build", "a/b/c@a_b",
      "a/b/c@.", "a/b/c@x.", "a/b//c", "a/b/é", "a/b/😀", "a/b/.mbt",
    ] {
    assert_true(qc_package_matches(input))
    assert_true(qc_coordinate_matches(input))
  }
  for module_path in ["a/b", ".../b", "a/b@v1", "a/b/c", "a/", "/b", "é/b"] {
    for
      input in [
        "", "c", "c/d.mbt@0", ".mbt", "c@", "c@x.", "c@a_b", "c//d", "c@1@2",
      ] {
      assert_true(qc_module_matches(module_path, input))
    }
  }
}
