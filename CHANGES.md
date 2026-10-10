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
  place: a Linux ELF binary matching the host architecture whose `ldd`
  reports unresolved libraries (for example a newer glibc than the host
  provides) aborts the install with a hint to build from source. Other
  formats and foreign architectures are skipped, and `--skip-compat-check`
  opts out.

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
