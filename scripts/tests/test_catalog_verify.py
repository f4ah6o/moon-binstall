"""What: dry-run output is classified without treating every failure as unsupported."""

from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from scripts.catalog import verify
from scripts.catalog.model import (
    REASON_HTTP_ERROR,
    REASON_MODULE_NOT_FOUND,
    REASON_NO_ASSET,
    REASON_NO_GITHUB_RELEASE,
    REASON_NO_RELEASE,
    REASON_RATE_LIMITED,
    REASON_RESOLVED,
    REASON_TIMEOUT,
    REASON_TRANSPORT,
    REASON_UNCLASSIFIED,
    UNKNOWN,
    UNSUPPORTED,
    VERIFIED,
)

TODAY = "2026-11-11"


def outcome(stdout="", stderr="", code=0, timed_out=False, launch_error=""):
    return verify.DryRunOutcome(
        returncode=code,
        stdout=stdout,
        stderr=stderr,
        timed_out=timed_out,
        launch_error=launch_error,
    )


def resolved(coordinate="acme/tool", target="linux-x86_64"):
    return (
        f"Resolved {coordinate}: source=github-releases {coordinate} "
        f"tag=v1.2.3 asset=tool-{target} binary=tool target={target}\n"
        "Would install https://example.invalid/tool -> /tmp/bin/tool\n"
    )


class ClassifyTests(unittest.TestCase):
    def test_verified(self):
        result = verify.classify(
            outcome(stdout=resolved()), "acme/tool", "linux-x86_64", TODAY
        )
        self.assertEqual(result.status, VERIFIED)
        self.assertEqual(result.reason, REASON_RESOLVED)
        self.assertEqual(result.tag, "v1.2.3")
        self.assertEqual(result.asset, "tool-linux-x86_64")
        self.assertEqual(result.binary, "tool")

    def test_verified_requires_matching_target(self):
        result = verify.classify(
            outcome(stdout=resolved(target="linux-aarch64")),
            "acme/tool",
            "linux-x86_64",
            TODAY,
        )
        self.assertEqual(result.status, UNKNOWN)
        self.assertEqual(result.reason, REASON_UNCLASSIFIED)

    def test_verified_requires_matching_coordinate(self):
        result = verify.classify(
            outcome(stdout=resolved(coordinate="other/tool")),
            "acme/tool",
            "linux-x86_64",
            TODAY,
        )
        self.assertEqual(result.status, UNKNOWN)

    def test_no_release_is_unsupported(self):
        stderr = (
            "moon-binstall: error[resolve]: query the GitHub release\n"
            "  target: https://api.github.com/repos/acme/tool/releases/latest\n"
            "  reason: acme/tool: no release was confirmed for acme/tool\n"
            "  action: check the repository name and tag, then retry\n"
        )
        result = verify.classify(
            outcome(stderr=stderr, code=1), "acme/tool", "linux-x86_64", TODAY
        )
        self.assertEqual(result.status, UNSUPPORTED)
        self.assertEqual(result.reason, REASON_NO_RELEASE)

    def test_no_asset_is_unsupported(self):
        stderr = (
            "moon-binstall: error[resolve]: resolve the install plan\n"
            "  reason: acme/tool: no matching prebuilt asset in release v1.2.3\n"
            "  action: check the coordinate and try again\n"
        )
        result = verify.classify(
            outcome(stderr=stderr, code=1), "acme/tool", "linux-x86_64", TODAY
        )
        self.assertEqual(result.status, UNSUPPORTED)
        self.assertEqual(result.reason, REASON_NO_ASSET)

    def test_module_not_found_is_unsupported(self):
        stderr = (
            "moon-binstall: error[resolve]: query the Mooncakes registry\n"
            "  reason: acme/tool/cmd/main: the Mooncakes module release was not found\n"
        )
        result = verify.classify(
            outcome(stderr=stderr, code=1),
            "acme/tool/cmd/main",
            "linux-x86_64",
            TODAY,
        )
        self.assertEqual(result.status, UNSUPPORTED)
        self.assertEqual(result.reason, REASON_MODULE_NOT_FOUND)

    def test_no_github_release_is_unsupported(self):
        stderr = (
            "moon-binstall: error[resolve]: query the GitHub release\n"
            "  reason: acme/tool/cmd/main: no GitHub release was found for acme/tool@1.0.0\n"
        )
        result = verify.classify(
            outcome(stderr=stderr, code=1),
            "acme/tool/cmd/main",
            "linux-x86_64",
            TODAY,
        )
        self.assertEqual(result.status, UNSUPPORTED)
        self.assertEqual(result.reason, REASON_NO_GITHUB_RELEASE)

    def test_rate_limit_is_unknown(self):
        stderr = (
            "moon-binstall: error[transport]: query the GitHub release\n"
            "  reason: acme/tool: the server returned HTTP 403 (rate limit reached)\n"
        )
        result = verify.classify(
            outcome(stderr=stderr, code=1), "acme/tool", "linux-x86_64", TODAY
        )
        self.assertEqual(result.status, UNKNOWN)
        self.assertEqual(result.reason, REASON_RATE_LIMITED)

    def test_http_429_is_unknown(self):
        stderr = (
            "moon-binstall: error[transport]: query the GitHub release\n"
            "  reason: acme/tool: the server returned HTTP 429 (rate limited)\n"
        )
        result = verify.classify(
            outcome(stderr=stderr, code=1), "acme/tool", "linux-x86_64", TODAY
        )
        self.assertEqual(result.status, UNKNOWN)
        self.assertEqual(result.reason, REASON_RATE_LIMITED)

    def test_transport_failure_is_unknown(self):
        stderr = (
            "moon-binstall: error[transport]: query the GitHub release\n"
            "  reason: acme/tool: communication failed (curl exit 56)\n"
        )
        result = verify.classify(
            outcome(stderr=stderr, code=1), "acme/tool", "linux-x86_64", TODAY
        )
        self.assertEqual(result.status, UNKNOWN)
        self.assertEqual(result.reason, REASON_TRANSPORT)

    def test_server_error_is_unknown(self):
        stderr = (
            "moon-binstall: error[transport]: query the GitHub release\n"
            "  reason: acme/tool: the server returned HTTP 502 (server error)\n"
        )
        result = verify.classify(
            outcome(stderr=stderr, code=1), "acme/tool", "linux-x86_64", TODAY
        )
        self.assertEqual(result.status, UNKNOWN)
        self.assertEqual(result.reason, REASON_HTTP_ERROR)

    def test_timeout_is_unknown(self):
        result = verify.classify(
            outcome(timed_out=True), "acme/tool", "linux-x86_64", TODAY
        )
        self.assertEqual(result.status, UNKNOWN)
        self.assertEqual(result.reason, REASON_TIMEOUT)

    def test_unclassified_failure_is_unknown(self):
        result = verify.classify(
            outcome(stderr="something broke", code=1),
            "acme/tool",
            "linux-x86_64",
            TODAY,
        )
        self.assertEqual(result.status, UNKNOWN)
        self.assertEqual(result.reason, REASON_UNCLASSIFIED)

    def test_launch_error_is_unknown(self):
        result = verify.classify(
            outcome(launch_error="no such file"), "acme/tool", "linux-x86_64", TODAY
        )
        self.assertEqual(result.status, UNKNOWN)
        self.assertEqual(result.reason, REASON_UNCLASSIFIED)


class SourceTests(unittest.TestCase):
    def test_github_source(self):
        self.assertEqual(
            verify.repository_from_source("github-releases acme/tool"), "acme/tool"
        )

    def test_mooncakes_source(self):
        self.assertEqual(
            verify.repository_from_source(
                "mooncakes+github-releases acme/tool/cmd/main (repository acme/tool)"
            ),
            "acme/tool",
        )

    def test_unknown_source(self):
        self.assertEqual(verify.repository_from_source("other"), "")


class RunTests(unittest.TestCase):
    def test_run_dry_run_passes_expected_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "fake.sh"
            args_file = root / "args.txt"
            script.write_text(
                "#!/bin/sh\n"
                'printf "%s\\n" "$@" > "$ARGS_FILE"\n'
                'echo "Resolved acme/tool: source=github-releases acme/tool '
                'tag=v1 asset=tool-linux-x86_64 binary=tool target=linux-x86_64"\n',
                encoding="utf-8",
            )
            script.chmod(0o755)
            result = verify.run_dry_run(
                str(script),
                "acme/tool",
                "linux-x86_64",
                str(root / "bin"),
                10,
                {"ARGS_FILE": str(args_file)},
            )
            self.assertTrue(result.ok)
            arguments = args_file.read_text(encoding="utf-8").splitlines()
            self.assertEqual(arguments[0], "acme/tool")
            self.assertIn("--target", arguments)
            self.assertIn("linux-x86_64", arguments)
            self.assertIn("--dry-run", arguments)
            self.assertIn("--bin-dir", arguments)

    def test_run_dry_run_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "slow.sh"
            script.write_text("#!/bin/sh\nsleep 5\n", encoding="utf-8")
            script.chmod(0o755)
            result = verify.run_dry_run(
                str(script), "acme/tool", "linux-x86_64", str(root / "bin"), 0.2
            )
            self.assertTrue(result.timed_out)
            self.assertFalse(result.ok)


if __name__ == "__main__":
    unittest.main()
