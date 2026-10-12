"""What: the curl write-out contract installer.mbt parses is emitted by real curl.

moon-binstall runs curl with
    --write-out '%{stderr}REPORT:%{json}\n%{stderr}HEADERS:%{header_json}'
and parses the REPORT:/HEADERS:-prefixed lines on stderr. This test runs that
exact invocation against a local HTTP server for 200, 404 and 403 responses
(with and without x-ratelimit-remaining) and asserts the line contract that
curl_report/curl_headers/curl_rate_limited rely on.
"""

import http.server
import json
import re
import subprocess
import threading
import unittest

WRITE_OUT = "%{stderr}REPORT:%{json}\n%{stderr}HEADERS:%{header_json}"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/ok":
            body, status = b"{}", 200
        elif self.path == "/limited":
            body, status = b"{}", 403
            self.send_response(status)
            self.send_header("content-type", "application/json")
            self.send_header("x-ratelimit-remaining", "0")
            self.send_header("x-ratelimit-limit", "60")
            self.end_headers()
            self.wfile.write(body)
            return
        else:
            body, status = b"{}", 404
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def curl_writeout(url):
    return subprocess.run(
        ["curl", "--silent", "--show-error", "--write-out", WRITE_OUT, url],
        capture_output=True,
        text=True,
    )


def sections(stderr):
    report, headers = None, []
    pending = ""
    for line in stderr.splitlines():
        if line.startswith("HEADERS:"):
            pending = line[len("HEADERS:"):]
        elif pending:
            pending += "\n" + line.strip()
        else:
            pending = ""
        if line.startswith("REPORT:"):
            pending = ""
            report = json.loads(line[len("REPORT:"):])
            continue
        if pending:
            try:
                # %{header_json} is pretty-printed over several lines.
                headers.append(json.loads(pending))
                pending = ""
            except json.JSONDecodeError:
                # curl < 7.84 prints "unknown --write-out variable" here.
                pass
    return report, headers


class CurlWriteOutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.thread.join()

    def test_report_line_is_distinct_from_headers(self):
        # Both %{json} and %{header_json} emit '{'-objects; the labels keep
        # the status report parseable (P0 regression guard).
        result = curl_writeout(self.base + "/ok")
        self.assertEqual(result.returncode, 0)
        report, _ = sections(result.stderr)
        self.assertIsNotNone(report, result.stderr)
        self.assertEqual(report["http_code"], 200)

    def test_404_status_reaches_the_report(self):
        result = curl_writeout(self.base + "/missing")
        self.assertEqual(result.returncode, 0)
        report, _ = sections(result.stderr)
        self.assertEqual(report["http_code"], 404)

    def test_403_rate_limit_evidence(self):
        result = curl_writeout(self.base + "/limited")
        self.assertEqual(result.returncode, 0)
        report, headers = sections(result.stderr)
        self.assertEqual(report["http_code"], 403)
        limited = any(
            "0" in h.get("x-ratelimit-remaining", []) for h in headers
        )
        import shutil, re as _re
        curl_version = _re.search(
            r"curl (\d+)\.(\d+)",
            subprocess.run(["curl", "--version"], capture_output=True, text=True).stdout,
        )
        if curl_version and (int(curl_version[1]), int(curl_version[2])) >= (7, 84):
            self.assertTrue(limited, result.stderr)
        else:
            # Older curls cannot emit header_json: degrade to a plain 403.
            self.assertFalse(limited)


if __name__ == "__main__":
    unittest.main()
