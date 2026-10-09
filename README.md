# moon-binstall

Install **precompiled**, SHA-256-verified MoonBit CLI binaries from GitHub Releases
or versioned Mooncakes modules. The resolver, CLI, platform matching, archive
inspection, filesystem operations and digest verification are implemented in
MoonBit (native). `curl` is used for HTTPS transfers because release downloads
involve redirects.

## Install from Mooncakes

Requires MoonBit, `curl`, and Linux or macOS. Install the CLI from
[Mooncakes](https://mooncakes.io/docs/f4ah6o/moon-binstall@0.1.2):

```sh
moon install f4ah6o/moon-binstall/cmd/main@0.1.2
mv "$HOME/.moon/bin/main" "$HOME/.moon/bin/moon-binstall"
export PATH="$HOME/.moon/bin:$PATH"

moon binstall --version
```

The executable package is `f4ah6o/moon-binstall/cmd/main`; the module root
`f4ah6o/moon-binstall` is the library. `moon install` builds the CLI from
Mooncakes source and installs it as `main` in `~/.moon/bin`. Rename it to
`moon-binstall` to enable `moon binstall`. Add the `export PATH` line to your
shell configuration if `~/.moon/bin` is not already on `PATH`.
See the [Moon install documentation](https://moonbitlang.github.io/moon/commands.html#moon-install)
for installation options.

Then install a tool:

```sh
moon binstall turtles
```

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

## Install Mooncakes packages

Use `owner/module/package[@version]` to select a package inside a Mooncakes
module. Three or more slash-separated components select Mooncakes metadata;
the existing two-component `owner/repo[@tag]` form and the aliases above keep
their GitHub Releases behavior. For a module with several packages, supply the
module once with `--module` and then list package paths:

```sh
moon binstall f4ah6o/moon-binstall/cmd/main@0.1.2 \
  --target linux-x86_64 --dry-run \
  --pkg-fmt bin \
  --pkg-url 'https://github.com/f4ah6o/moon-binstall/releases/download/v{version}/moon-binstall-{target}'

moon binstall owner/module/cmd/first@1.2.0 owner/module/cmd/second@2.0.0 \
  --bin-dir "$HOME/.local/bin"

moon binstall --module owner/module cmd/first cmd/second@2.0.0
```

Without an explicit `@version`, the installer asks Mooncakes for the module's
latest release and pins the returned exact version for source and GitHub release
resolution. It checks that Mooncakes returned the requested module and version,
rejects yanked releases, and verifies the module source ZIP against the registry
checksum before reading its optional `moon-binstall.json`. That source checksum
authenticates the source archive only. The selected GitHub executable still
needs GitHub's independent `sha256:<64 hex digits>` release-asset digest.

A module may put an optional `moon-binstall.json` at its source root to describe
each package's release asset. For example:

```json
{
  "repository": "https://github.com/owner/repo",
  "packages": [
    {
      "package": "cmd/main",
      "binary": "tool",
      "pkg-url": "{repo}/releases/download/v{version}/{bin}-{target}{archive-suffix}",
      "pkg-fmt": "tgz",
      "bin-path": "{package}/{bin}"
    }
  ]
}
```

For Mooncakes installs, the GitHub repository comes from `metadata.repository`
in the registry response. `repository` in `moon-binstall.json` is used only
with `--manifest-path FILE`; there it defaults to
`https://github.com/{owner}/{module}` when omitted. Each package entry uses its
MoonBit package path. Optional `binary` sets the installed executable name.
`pkg-url` selects the asset URL template and
`pkg-fmt` selects `bin`, `tgz`, `tar.gz` or `zip`. Archive packages default to
the executable name as their member path; `bin-path` or the CLI's `--bin-path`
can select a different member. `--pkg-url`, `--pkg-fmt` and `--bin-path`
override manifest values for one invocation. A local manifest can be supplied
with `--manifest-path FILE`; this is limited to one package and skips Mooncakes
lookup.

Templates support `{repo}` (the module GitHub repository URL), `{name}` or
`{module}` (the module's last path component), `{package}`, `{bin}` or
`{binary}`, `{version}` (without a leading `v`), `{target}`,
`{archive-suffix}` and `{archive-format}`. A template using
`{archive-suffix}` should also set `pkg-fmt` or pass `--pkg-fmt`, so the suffix
and extraction mode agree. Resolved asset URLs must remain under the exact
GitHub repository and release tag selected by the API.

By default, the resolver checks common names such as
`<binary>-<target>`, `<binary>-<target>-<version>` and
`<binary>-<version>-<target>`, including `.tar.gz`, `.tgz` and `.zip` archive
suffixes. Supplying `--pkg-fmt` restricts matching to that format, so a raw
asset cannot shadow a requested archive.

`--bin-dir` continues to mean the destination directory for compatibility.
Use `--bin-path` for a member inside an archive. `--version` applies to one
package; use `@VERSION` on each coordinate in a batch. Multiple packages that
resolve to executable names that differ only by ASCII case are rejected on all
platforms (for example, `tool` and `Tool`).

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

GitHub Releases must include a matching raw executable or a supported `.tgz`,
`.tar.gz` or `.zip` archive for the requested target. Every selected asset must
include GitHub's `sha256:<64 hex digits>` digest metadata. Missing assets or
digests are errors; installation never falls back to building from source.
The built-in target names are `linux-x86_64`, `linux-aarch64`, `darwin-x86_64`
and `darwin-aarch64`. The resolver accepts all four names; this repository's
release workflow currently builds Linux x86_64, Linux aarch64 and macOS
aarch64 assets. It does not publish an Intel macOS asset.

By default the latest non-prerelease GitHub Release is used. Specify
`@<tag>` for a release tag. `--dry-run` resolves without installing,
`--force` replaces an existing **regular file** after verification, and
`--bin-dir` or `MOON_BINSTALL_DIR` overrides `$HOME/.local/bin`. Install batches
are fully downloaded and verified before the first destination is replaced.
The destination directory must be added to `PATH`.

## Security

No downloaded asset is executed during installation. Registry, GitHub API and
asset transfers use HTTPS and redirects must remain HTTPS. The Mooncakes source
ZIP checksum and selected GitHub release asset digest are checked separately.
Before extraction, the installer validates every archive entry, including
unselected members and entries in the Mooncakes source ZIP. Member paths must
use ASCII letters, digits, `.`, `_`, `-`, `+` and `/` separators, with no
whitespace; it rejects traversal, duplicate names, links, special files and
option-like paths. It reads only the chosen regular member,
limits archive listings to 16 MiB and 100,000 entries, caps selected binary
output at 128 MiB, stages files in private directories on the destination
filesystem, and renames only after verification. Symlink and non-regular
destinations remain blocked, including with `--force`.

Runtime requirements are `curl` 8.4.0 or newer and Linux or macOS. The minimum
version is required because curl only enforces the download size limit during
transfers with an unknown content length starting in 8.4.0. Asset downloads
are capped at 256 MiB, and captured API/source metadata at 16 MiB. Installing
`.tgz` or `.tar.gz` assets also requires `tar` with gzip support; installing
`.zip` assets requires `zipinfo` and `unzip` (provided by the common `unzip`
package on Ubuntu). `moon test` additionally requires Python 3 to create
deterministic archive fixtures; production installation does not invoke Python.

## Scope compared with cargo-binstall

This project adapts the binary-install workflow to MoonBit: it resolves
Mooncakes module metadata, selects versioned GitHub release assets, supports
package batches and a source-controlled `moon-binstall.json`, verifies
independent source and executable checksums, and safely installs raw, tar-gzip
or zip binaries. It does not implement Cargo- or Rust-specific behavior: it
does not read Cargo manifests, query crates.io, invoke `cargo` or `rustup`,
build Rust source, install Rust dependencies, or support arbitrary registries
and external asset hosts. The resolver accepts exactly
`linux-x86_64`, `linux-aarch64`, `darwin-x86_64` and `darwin-aarch64`; Windows
is not supported. This repository publishes release binaries for Linux
x86_64, Linux aarch64 and macOS aarch64.

The repository's own `moon-binstall.json` maps MoonBit package `cmd/main` to
the `moon-binstall` executable and the raw release asset naming convention.
This lets a published Mooncakes source version use the same release contract
without command-line asset overrides.

## Mooncakes

This project can publish its MoonBit source module to Mooncakes as
`f4ah6o/moon-binstall`. GitHub Releases remain the distribution channel
for prebuilt standalone native executables.

The Mooncakes registry publication is a **separate authenticated step**.
From an authorized workstation with a Mooncakes `f4ah6o` account:

```sh
moon login
moon update
moon install
moon package --list
moon publish
```

After the versioned GitHub Release succeeds, the `Publish Mooncakes`
GitHub Actions workflow publishes the corresponding source module using the
`MOONCAKES_CREDENTIALS_JSON` repository secret. Store the complete contents
of `~/.moon/credentials.json` from `moon login` in GitHub's
Settings → Secrets and variables → Actions. Do not put credentials in
committed files or issue comments. The workflow uses temporary credentials,
deletes the file on completion, and supports manual retry.

Publishing requires this GitHub Secret to be configured before the release
workflow is merged. Registry publication is only complete once
`moon publish` reports success and the Mooncakes module/version is visible.
