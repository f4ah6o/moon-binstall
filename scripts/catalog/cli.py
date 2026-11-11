"""Command line entry point for the catalog scan.

Usage:
    python3 -m scripts.catalog scan
    python3 -m scripts.catalog check
    python3 -m scripts.catalog render

``scan`` discovers candidates, verifies them with the existing resolver and
writes CATALOG.md only when its content changed. ``check`` re-renders from the
state without network access and fails when the committed file is stale.
"""

from __future__ import annotations

import argparse
import datetime
import json
import sys
import tempfile
from pathlib import Path

from . import adoption, discover, generate, state as state_module, verify
from .http import Client
from .model import TARGETS


def utc_today() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def _targets(value: str) -> list[str]:
    names = [item.strip() for item in value.split(",") if item.strip()]
    unknown = [name for name in names if name not in TARGETS]
    if unknown:
        raise argparse.ArgumentTypeError(f"unknown target: {', '.join(unknown)}")
    return names


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python3 -m scripts.catalog",
        description="Discover and verify moon-binstall compatible CLIs",
    )
    parser.add_argument("--state", default="scripts/catalog/state.json")
    parser.add_argument("--output", default="CATALOG.md")
    parser.add_argument("--today", default="")
    sub = parser.add_subparsers(dest="command", required=True)

    scan = sub.add_parser("scan", help="discover, verify and regenerate")
    scan.add_argument("--binary", default="moon-binstall")
    scan.add_argument("--readme", default="README.md")
    scan.add_argument("--self-repository", default="f4ah6o/moon-binstall")
    scan.add_argument("--targets", type=_targets, default=list(TARGETS))
    scan.add_argument("--jobs", type=int, default=4)
    scan.add_argument("--timeout", type=float, default=180.0)
    scan.add_argument("--http-timeout", type=float, default=30.0)
    scan.add_argument("--http-retries", type=int, default=3)
    scan.add_argument("--search-pages", type=int, default=2)
    scan.add_argument("--always-budget", type=int, default=100)
    scan.add_argument("--rotate-budget", type=int, default=100)
    scan.add_argument("--full", action="store_true")
    scan.add_argument("--verbose", action="store_true")

    check = sub.add_parser("check", help="verify the committed catalog")
    check.add_argument("--quiet", action="store_true")

    sub.add_parser("render", help="print the catalog to stdout")
    return parser


def cmd_scan(args: argparse.Namespace) -> int:
    state_path = Path(args.state)
    output_path = Path(args.output)
    try:
        current = state_module.load_state(state_path)
    except state_module.StateError as error:
        log(f"catalog: {error}")
        return 1

    today = args.today or utc_today()
    readme_path = Path(args.readme)
    readme = readme_path.read_text(encoding="utf-8") if readme_path.exists() else ""
    client = Client(timeout=args.http_timeout, retries=args.http_retries)

    discovery = discover.discover(
        client,
        readme_text=readme,
        max_search_pages=args.search_pages,
        log=log,
    )
    for warning in discovery.warnings:
        log(f"catalog: warning: {warning}")
    if discovery.sources_ok == 0:
        log("catalog: every discovery source failed; keeping the existing catalog")
        return 1

    selection = state_module.select_candidates(
        current,
        discovery.candidates,
        always_budget=args.always_budget,
        rotate_budget=args.rotate_budget,
        full=args.full,
        rotation_seed=datetime.date.fromisoformat(today).toordinal(),
    )
    log(
        "catalog: "
        f"{len(discovery.candidates)} candidates discovered, "
        f"{selection.always} always + {selection.rotate} rotating selected, "
        f"{selection.skipped} not checked this run"
    )

    with tempfile.TemporaryDirectory(prefix="moon-binstall-catalog-") as bin_root:
        results = verify.verify_candidates(
            args.binary,
            selection.candidates,
            targets=args.targets,
            jobs=args.jobs,
            timeout=args.timeout,
            today=today,
            bin_root=bin_root,
            log=log if args.verbose else None,
        )

    stats = state_module.merge_results(
        current, selection.candidates, results, today
    )
    adoption_entries, adoption_warnings = adoption.collect(
        client,
        discovery.hits,
        self_repository=args.self_repository,
        log=log,
    )
    for warning in adoption_warnings:
        log(f"catalog: warning: {warning}")
    adoption_changed = state_module.merge_adoption(current, adoption_entries, today)

    changed = generate.update_catalog(current, output_path, today)
    state_module.save_state(state_path, current)

    counts = state_module.summarize(current)
    summary = {
        "date": today,
        "discovered": len(discovery.candidates),
        "selected": len(selection.candidates),
        "skipped": selection.skipped,
        "new_candidates": stats.new_candidates,
        "changed_results": stats.changed,
        "retained_previous": stats.retained,
        "unknown_results": stats.unknown,
        "adoption_changed": adoption_changed,
        "catalog_changed": changed,
        **counts,
    }
    log(
        "catalog: "
        f"{counts['verified']} verified, {counts['unsupported']} unsupported, "
        f"{counts['unknown']} unknown, {counts['adoption']} adoption entries"
    )
    log(f"catalog: {'updated' if changed else 'unchanged'} {output_path}")
    print(json.dumps(summary, sort_keys=True))
    return 0


def cmd_check(args: argparse.Namespace) -> int:
    state_path = Path(args.state)
    output_path = Path(args.output)
    try:
        current = state_module.load_state(state_path)
    except state_module.StateError as error:
        log(f"catalog: {error}")
        return 1
    today = args.today or utc_today()
    if generate.check_catalog(current, output_path, today):
        if not args.quiet:
            log(f"catalog: {output_path} matches {state_path}")
        return 0
    log(
        f"catalog: {output_path} is stale; run "
        f"'python3 -m scripts.catalog scan' and commit the result"
    )
    return 1


def cmd_render(args: argparse.Namespace) -> int:
    try:
        current = state_module.load_state(Path(args.state))
    except state_module.StateError as error:
        log(f"catalog: {error}")
        return 1
    today = args.today or utc_today()
    sys.stdout.write(generate.render_catalog(current, today))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "scan":
        return cmd_scan(args)
    if args.command == "check":
        return cmd_check(args)
    if args.command == "render":
        return cmd_render(args)
    parser.error("unknown command")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
