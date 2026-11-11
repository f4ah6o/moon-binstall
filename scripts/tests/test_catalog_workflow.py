"""What: the catalog workflow has the required triggers, limits and permissions."""

from pathlib import Path
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
        self.assertIn('git fetch origin "$branch"', publish["run"])
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


if __name__ == "__main__":
    unittest.main()
