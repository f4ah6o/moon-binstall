"""What: the catalog workflow has the required triggers, limits and permissions."""

import os
from pathlib import Path
import subprocess
import tempfile
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

try:
    import yaml
except ImportError:  # pragma: no cover - CI installs python3-yaml
    yaml = None

WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/catalog.yml"


@unittest.skipIf(yaml is None, "PyYAML is required for workflow validation")
class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding="utf-8")
        cls.data = yaml.safe_load(cls.text)
        # PyYAML resolves the unquoted `on` key to True (YAML 1.1).
        cls.triggers = cls.data.get("on", cls.data.get(True))

    def test_triggers(self):
        self.assertIn("workflow_dispatch", self.triggers)
        self.assertIn("schedule", self.triggers)
        self.assertEqual(self.triggers["schedule"][0]["cron"], "23 4 * * *")

    def test_top_level_permissions_are_read_only(self):
        self.assertEqual(self.data["permissions"], {"contents": "read"})

    def test_job_permissions_are_minimal(self):
        job = self.data["jobs"]["catalog"]
        self.assertEqual(
            job["permissions"],
            {"contents": "write", "pull-requests": "write"},
        )

    def test_timeout_and_concurrency(self):
        self.assertEqual(self.data["jobs"]["catalog"]["timeout-minutes"], 60)
        self.assertEqual(self.data["concurrency"]["group"], "catalog")

    def test_scan_uses_the_built_binary_and_a_token(self):
        steps = self.data["jobs"]["catalog"]["steps"]
        scan = next(step for step in steps if step.get("name") == "Scan and generate CATALOG.md")
        self.assertIn("GITHUB_TOKEN", scan["env"])
        self.assertIn("secrets.CATALOG_GITHUB_TOKEN", scan["env"]["GITHUB_TOKEN"])
        self.assertIn("github.token", scan["env"]["GITHUB_TOKEN"])
        self.assertIn("--binary", scan["run"])
        self.assertIn("scripts.catalog", scan["run"])

    def test_catalog_is_checked_before_commit(self):
        steps = self.data["jobs"]["catalog"]["steps"]
        names = [step.get("name") for step in steps]
        self.assertLess(
            names.index("Scan and generate CATALOG.md"),
            names.index("Verify the catalog is reproducible"),
        )
        self.assertLess(
            names.index("Verify the catalog is reproducible"),
            names.index("Open a pull request when the catalog changed"),
        )

    def test_pull_request_only_when_changed(self):
        steps = self.data["jobs"]["catalog"]["steps"]
        publish = next(
            step
            for step in steps
            if step.get("name") == "Open a pull request when the catalog changed"
        )
        self.assertIn("git diff --quiet", publish["run"])
        self.assertIn("gh pr create", publish["run"])
        self.assertIn('git push origin "$branch"', publish["run"])
        self.assertNotIn("--force", publish["run"])

    def test_no_untrusted_workflow_execution(self):
        self.assertNotIn("pull_request_target", self.text)
        self.assertNotIn("workflow_run", self.text)
        self.assertNotIn("actions/checkout@v4\n        with:\n          ref:", self.text)

    def test_no_token_is_printed(self):
        self.assertNotIn("echo $GITHUB_TOKEN", self.text)
        self.assertNotIn("echo \"$GITHUB_TOKEN\"", self.text)
        self.assertNotIn("set -x", self.text)


@unittest.skipIf(yaml is None, "PyYAML is required for workflow validation")
class PublishWorkflowTests(unittest.TestCase):
    def run_publish(self, existing=False, identical=False, remote_error=False):
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        steps = workflow["jobs"]["catalog"]["steps"]
        script = next(s["run"] for s in steps if s.get("name") == "Open a pull request when the catalog changed")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            remote = root / "remote.git"

            def git(*args):
                return subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True, text=True)

            subprocess.run(["git", "init", "--bare", str(remote)], check=True, capture_output=True)
            subprocess.run(["git", "init", "-b", "main", str(repo)], check=True, capture_output=True)
            git("config", "user.name", "Test")
            git("config", "user.email", "test@example.org")
            (repo / "scripts/catalog").mkdir(parents=True)
            (repo / "CATALOG.md").write_text("main catalog\n")
            (repo / "scripts/catalog/state.json").write_text("main state\n")
            git("add", ".")
            git("commit", "-m", "base")
            git("remote", "add", "origin", str(remote))
            git("push", "origin", "main")
            if existing:
                git("checkout", "-b", "catalog/update")
                (repo / "CATALOG.md").write_text("generated catalog\n" if identical else "previous catalog\n")
                (repo / "scripts/catalog/state.json").write_text("generated state\n" if identical else "previous state\n")
                git("add", ".")
                git("commit", "-m", "previous update")
                git("push", "origin", "catalog/update")
                git("checkout", "main")
            (repo / "CATALOG.md").write_text("generated catalog\n")
            (repo / "scripts/catalog/state.json").write_text("generated state\n")
            if remote_error:
                git("remote", "set-url", "origin", str(root / "missing.git"))
            bindir = root / "bin"
            bindir.mkdir()
            gh = bindir / "gh"
            gh.write_text('#!/bin/sh\nif [ "$1 $2" = "pr view" ]; then exit 1; fi\nprintf "%s\\n" "$*" >> "$GH_CALL_LOG"\n')
            gh.chmod(0o755)
            env = os.environ.copy()
            env["PATH"] = str(bindir) + os.pathsep + env["PATH"]
            env["GH_CALL_LOG"] = str(root / "gh.log")
            result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", script], cwd=repo, env=env, capture_output=True, text=True)
            if remote_error:
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((root / "gh.log").exists())
                return
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(git("show", "origin/catalog/update:CATALOG.md").stdout, "generated catalog\n")
            self.assertEqual(git("show", "origin/catalog/update:scripts/catalog/state.json").stdout, "generated state\n")
            self.assertIn("pr create", (root / "gh.log").read_text())

    def test_generated_files_are_published_on_existing_branch(self):
        self.run_publish(existing=True)

    def test_existing_identical_update_can_create_missing_pr(self):
        self.run_publish(existing=True, identical=True)

    def test_generated_files_are_published_on_new_branch(self):
        self.run_publish()

    def test_remote_failure_does_not_create_a_pr(self):
        self.run_publish(existing=True, remote_error=True)


if __name__ == "__main__":
    unittest.main()

