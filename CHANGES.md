# Changes

## Unreleased

### Added

### Changed

### Fixed

### Deprecated

### Removed

### Security

### Migration

## 0.1.6 - 2026-10-10

### Added

- A compatibility check runs on each staged binary before it is moved into
  place, without executing the binary or running `ldd` on it. For a Linux
  ELF binary matching the host architecture the installer reads `PT_INTERP`,
  `DT_NEEDED` and required `GLIBC_*` symbol versions, then aborts with a
  source-build hint when the interpreter is missing, a library is
  unresolvable via the host loader cache and library directories, or the
  host glibc is too old. Other formats and foreign architectures are
  skipped, and `--skip-compat-check` opts out.
- Package entries and per-target overrides in `moon-binstall.json` accept an
  optional `glibc-min` (e.g. `"2.38"`). When an install targets the host's
  own Linux architecture the declared minimum is checked before
  downloading: a musl host or an older glibc aborts with a source-build
  hint; cross-architecture fetches are unaffected. The publish workflow
  measures each Linux release asset and stamps a shared value, or
  per-target overrides when the results differ, into the published
  manifest.

### Changed

## 0.1.5 - 2026-10-10

### Added

### Changed

- The module root package `f4ah6o/moon-binstall` is now the executable, so
  `moon install f4ah6o/moon-binstall` installs `moon-binstall` directly with
  no `/cmd/main` suffix or rename step. `f4ah6o/moon-binstall/cmd/main` remains
  available and installs the same binary as `main`.

### Fixed

### Deprecated

### Removed

### Security

### Migration

- `moon install f4ah6o/moon-binstall` now installs `~/.moon/bin/moon-binstall`
  directly. The previous `mv ~/.moon/bin/main ~/.moon/bin/moon-binstall` step is
  no longer needed; installing via `f4ah6o/moon-binstall/cmd/main` still
  requires it.

## 0.1.4 - 2026-10-09

### Added

### Changed

### Fixed

### Deprecated

### Removed

- Removed the built-in `turtles`, `hotpath`, and `dsh` package shortcuts. GitHub coordinates now follow the same `owner/repo[@tag]` rule, and repository names ending in `.mbt` use their generic binary name.

### Security

### Migration

- Replace `turtles`, `hotpath`, or `dsh` with `gpui-mbt/turtles.mbt`, `gpui-mbt/hotpath.mbt`, or `f4ah6o/dsh.mbt`, adding `@tag` when needed. `gpui-mbt/hotpath.mbt` now installs `hotpath`.
