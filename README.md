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

## Release contract

The repository must publish a **raw executable** named
`<binary>-<platform>`, where platform is
`linux-x86_64`, `linux-aarch64`, `darwin-x86_64` or `darwin-aarch64`.
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
