"""What: measure_glibc_min.sh propagates failures and only prints real maxima."""

import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "measure_glibc_min.sh"


def _write_exe(path: Path, body: str) -> None:
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class MeasureGlibcMinTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.bin = root / "bin"
        self.dest = root / "dest"
        self.bin.mkdir()
        self.dest.mkdir()
        self.env = dict(os.environ)
        self.env["PATH"] = f"{self.bin}{os.pathsep}{self.env['PATH']}"

    def stub_gh(self, body: str) -> None:
        _write_exe(self.bin / "gh", body)

    def stub_objdump(self, body: str) -> None:
        _write_exe(self.bin / "objdump", body)

    def measure(self):
        return subprocess.run(
            ["bash", str(SCRIPT), "cli-linux-x86_64", "v1.2.3", str(self.dest)],
            capture_output=True,
            text=True,
            env=self.env,
        )

    def test_failed_download_is_an_error_not_empty(self):
        self.stub_gh("#!/usr/bin/env bash\nexit 1\n")
        self.stub_objdump("#!/usr/bin/env bash\nexit 1\n")
        result = self.measure()
        self.assertNotEqual(result.returncode, 0)

    def test_failed_objdump_is_an_error_not_empty(self):
        # gh stub "downloads" the asset by touching the -O path.
        self.stub_gh(
            "#!/usr/bin/env bash\n"
            'out=""\n'
            "while [ $# -gt 0 ]; do\n"
            '  if [ "$1" = "-O" ]; then out="$2"; shift 2; continue; fi\n'
            "  shift\n"
            "done\n"
            'touch "$out"\n'
        )
        self.stub_objdump("#!/usr/bin/env bash\nexit 1\n")
        result = self.measure()
        self.assertNotEqual(result.returncode, 0)

    def test_prints_highest_glibc_version(self):
        self.stub_gh(
            "#!/usr/bin/env bash\n"
            'out=""\n'
            "while [ $# -gt 0 ]; do\n"
            '  if [ "$1" = "-O" ]; then out="$2"; shift 2; continue; fi\n'
            "  shift\n"
            "done\n"
            'touch "$out"\n'
        )
        self.stub_objdump(
            "#!/usr/bin/env bash\n"
            'printf "0 g DF .text 0 GLIBC_2.34 foo\\n"\n'
            'printf "0 g DF .text 0 GLIBC_2.38 bar\\n"\n'
            'printf "0 g DF .text 0 GLIBC_2.2.5 baz\\n"\n'
        )
        result = self.measure()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "2.38")

    def test_no_glibc_symbols_is_a_valid_empty_result(self):
        self.stub_gh(
            "#!/usr/bin/env bash\n"
            'out=""\n'
            "while [ $# -gt 0 ]; do\n"
            '  if [ "$1" = "-O" ]; then out="$2"; shift 2; continue; fi\n'
            "  shift\n"
            "done\n"
            'touch "$out"\n'
        )
        self.stub_objdump(
            "#!/usr/bin/env bash\n"
            'printf "DYNAMIC SYMBOL TABLE:\\n"\n'
            'printf "0 g DF .text 0 foo\\n"\n'
        )
        result = self.measure()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "")


if __name__ == "__main__":
    unittest.main()
