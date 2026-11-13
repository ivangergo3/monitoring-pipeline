import copy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import monitor


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/slow":
            time.sleep(0.15)
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/ok")
        else:
            self.send_response(503 if self.path == "/fail" else 200)
        self.end_headers()

    def log_message(self, *args):
        pass


class MonitorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def app(self, path="/ok", **overrides):
        return {"id": "test", "name": "Test app", "url": self.base + path, **overrides}

    def test_success(self):
        result = monitor.check(self.app())
        self.assertEqual(result["status"], "healthy")
        self.assertEqual(result["http_status"], 200)
        self.assertIsNone(result["error"])

    def test_failure_is_a_publishable_result(self):
        result = monitor.check(self.app("/fail"))
        self.assertEqual(result["status"], "unhealthy")
        self.assertEqual(result["http_status"], 503)
        self.assertIn("received 503", result["error"])

    def test_custom_status(self):
        self.assertEqual(monitor.check(self.app("/fail", expected_status=503))["status"], "healthy")

    def test_redirect(self):
        self.assertEqual(monitor.check(self.app("/redirect"))["status"], "healthy")

    def test_timeout(self):
        result = monitor.check(self.app("/slow", timeout_seconds=0.02))
        self.assertEqual(result["status"], "unhealthy")
        self.assertIsNone(result["http_status"])
        self.assertTrue(result["error"])

    def test_connection_error(self):
        with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as unused:
            port = unused.server_port
        result = monitor.check(self.app(url=f"http://127.0.0.1:{port}"))
        self.assertEqual(result["status"], "unhealthy")
        self.assertTrue(result["error"])

    def test_missing_corrupt_and_mismatched_results(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = {"applications": [self.app()]}
            for content in (None, "broken", '{"id":"different","status":"healthy"}'):
                if content:
                    (root / "test.json").write_text(content)
                report = monitor.build(config, root, root / "out")
                self.assertEqual(report["applications"][0]["status"], "unknown")

    def test_html_escaping_and_json_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = self.app(name='<script>alert("x")</script>')
            (root / "test.json").write_text(json.dumps(monitor.check(app)))
            report = monitor.build({"applications": [app]}, root, root / "out")
            page = (root / "out/index.html").read_text()
            self.assertNotIn("<script>", page)
            self.assertIn("&lt;script&gt;", page)
            self.assertNotIn("{{", page)
            self.assertEqual(json.loads((root / "out/status.json").read_text()), report)

    def test_invalid_config(self):
        good = {"applications": [self.app()]}
        invalid = [[], [self.app(), self.app()], [self.app(id="../escape")],
                   [self.app(url="javascript:alert(1)")], [self.app(url="https://user:pass@example.com")],
                   [self.app(timeout_seconds=0)], [self.app(timeout_seconds=61)],
                   [self.app(expected_status=True)], [self.app(name="")]]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "apps.json"
            path.write_text(json.dumps(good))
            self.assertEqual(monitor.load_config(path), good)
            for apps in invalid:
                with self.subTest(apps=apps):
                    bad = copy.deepcopy(good)
                    bad["applications"] = apps
                    path.write_text(json.dumps(bad))
                    with self.assertRaises(ValueError):
                        monitor.load_config(path)


if __name__ == "__main__":
    unittest.main()
