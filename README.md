# moon-binstall

Install **precompiled**, SHA-256-verified MoonBit CLI binaries from GitHub Releases.
The resolver, CLI, platform matching, filesystem operations and digest verification
are implemented in MoonBit (native). `curl` is used only for HTTPS transfers
because release asset downloads involve redirects.

## Build

Requires MoonBit, `curl`, and Linux or macOS:

```sh
moon update
moon install
moon test --target native
moon build --release --target native
moon run cmd/main --target native -- --help
```

The generated executable is `_build/native/release/build/cmd/main/main.exe`
(the exact output path can vary with toolchain versions).

## Use as a `moon` subcommand

The official Moon CLI dispatches unknown subcommands to executables named
`moon-<subcommand>` on `PATH`. Install the `moon-binstall` binary under that
**exact filename** to enable `moon binstall` (no Moon CLI patch or shell alias).

To build and bootstrap from source:

```sh
moon update
moon install
moon build cmd/main --target native --release

mkdir -p "${MOON_HOME:-$HOME/.moon}/bin"
binary=$(find _build/native/release/build -type f -name main.exe -print)
test -n "$binary"
install -m 755 "$binary" "${MOON_HOME:-$HOME/.moon}/bin/moon-binstall"
export PATH="${MOON_HOME:-$HOME/.moon}/bin:$PATH"

moon binstall --version
moon binstall turtles
moon binstall hotpath
moon binstall dsh
moon binstall turtles@v0.4.0
```

`moon binstall` forwards arguments unchanged to `moon-binstall`. The target
repositories must first publish matching verified GitHub Releases; until then
the installer exits with an explicit missing-release error. `moon --help`
does not necessarily enumerate externally discovered commands.

## Usage

```sh
moon run cmd/main --target native -- turtles --dry-run
moon run cmd/main --target native -- turtles@v0.4.0 --bin-dir "$HOME/.local/bin"
moon run cmd/main --target native -- gpui-mbt/turtles.mbt
moon run cmd/main --target native -- hotpath
moon run cmd/main --target native -- f4ah6o/dsh.mbt
```

Once packaged as a native executable, invoke `moon-binstall` directly.

Supported aliases:

| Alias | Repository | Installed executable |
| --- | --- | --- |
| `turtles` | [gpui-mbt/turtles.mbt](https://github.com/gpui-mbt/turtles.mbt) | `turtles` |
| `hotpath` | [gpui-mbt/hotpath.mbt](https://github.com/gpui-mbt/hotpath.mbt) | `hotpath-report` (example executable only) |
| `dsh` | [f4ah6o/dsh.mbt](https://github.com/f4ah6o/dsh.mbt) | `dsh` |

`hotpath.mbt` is a **library**, not a native CLI; to depend on the
library in your project, use `moon add f4ah6o/hotpath` instead. The
`hotpath-report` binary is the repository's terminal-report example.

## Versioned native releases

Edit the `version` field in `moon.mod` to the intended SemVer version
(e.g., `0.1.0` to `0.1.1`) and merge that change into `main`.
The release workflow compares the previous and new **version values**, not
just the file modification date. On a version increase it validates
version consistency, builds three native platforms, then creates the
immutable `vX.Y.Z` tag and GitHub Release for the matching commit.
Other changes to `moon.mod` do not publish. Version downgrades fail.

An explicitly pushed `vX.Y.Z` tag remains supported only when the tag
matches `moon.mod`; the workflow never edits source versions or bumps
versions on its own. Publishing requires successful binary builds and
GitHub Actions permission to create a Release.

Update the version in `installer.mbt` as well so `moon binstall --version` matches.

## Release contract

The repository must publish a **raw executable** named
`<binary>-<platform>`, where platform is
`linux-x86_64`, `linux-aarch64` or `darwin-aarch64` in the provided CI workflow.
`darwin-x86_64` is recognized by the resolver, but the current MoonBit setup
workflow cannot build for Intel macOS; no matching release binary is published.
Releases must include GitHub's `sha256:<64 hex digits>` digest metadata
for each asset. Missing assets or digests are errors — no unverified
installation or silent source-build fallback.

By default the latest non-prerelease GitHub Release is used. Specify
`@<tag>` for a release tag. `--dry-run` resolves without installing,
`--force` replaces an existing **regular file** after verification, and
`--bin-dir` or `MOON_BINSTALL_DIR` overrides `$HOME/.local/bin`.
The destination directory must be added to `PATH`.

## Security

No downloaded asset is executed during installation. Download uses HTTPS
only, checksum verification is mandatory, unsupported platforms fail closed,
and the final rename occurs only after verification. Symlink destinations
and existing files are rejected unless explicitly permitted as regular files
with `--force`.

## Current release status

The three initial repositories did not have GitHub Releases as of
2026-10-08. Until matching verified release assets are published,
installation correctly reports an unavailable release/asset rather than
pretending success.

## Mooncakes

This project also publishes its MoonBit source module to Mooncakes as
`f4ah6o/moon-binstall`. GitHub Releases remain the distribution channel
for prebuilt standalone native executables.

The Mooncakes upload uses `moon publish`, authenticated with the
`f4ah6o` Mooncakes account. A GitHub Actions workflow validates
`moon package --list` before any upload.
