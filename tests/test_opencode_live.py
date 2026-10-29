"""Opt-in real OpenCode test, using a local fake model (no paid API calls).

Run after ./install.sh --opencode:
    RUN_OPENCODE_LIVE=1 python3 -m unittest discover -s tests -p test_opencode_live.py -v
"""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.environ.get("RUN_OPENCODE_LIVE") == "1", "opt-in real OpenCode test")
class OpenCodeLiveTests(unittest.TestCase):
    def test_real_plugin_continues_and_stops_at_budget(self):
        requests = []
        hold_response = threading.Event()
        request_started = threading.Event()
        release_response = threading.Event()

        class Model(BaseHTTPRequestHandler):
            def handle(self):
                try:
                    super().handle()
                except (BrokenPipeError, ConnectionResetError):
                    # The interruption test deliberately closes the model stream.
                    pass

            def log_message(self, *args):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                requests.append(body)
                if hold_response.is_set():
                    request_started.set()
                    release_response.wait(timeout=10)
                response = {
                    "id": "chatcmpl-goal-test", "object": "chat.completion", "created": 1,
                    "model": "test", "choices": [{"index": 0, "message": {
                        "role": "assistant", "content": "Test turn finished; objective remains incomplete.",
                    }, "finish_reason": "stop"}],
                    "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
                }
                if body.get("stream"):
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.end_headers()
                    for delta, finish in [({"role": "assistant", "content": "Test turn finished."}, None), ({}, "stop")]:
                        chunk = {"id": "chatcmpl-goal-test", "object": "chat.completion.chunk",
                                 "created": 1, "model": "test", "choices": [
                                     {"index": 0, "delta": delta, "finish_reason": finish}]}
                        self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
                    self.wfile.write(b"data: [DONE]\n\n")
                else:
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    self.wfile.write(json.dumps(response).encode())

        server = ThreadingHTTPServer(("127.0.0.1", 0), Model)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        with tempfile.TemporaryDirectory(prefix="goal-opencode-live-") as directory:
            project = Path(directory).resolve()
            directory = str(project)
            # No local goal/plugin definitions: exercise the global installation.
            (project / "opencode.json").write_text(json.dumps({
                "$schema": "https://opencode.ai/config.json",
                "model": "goal-test/test",
                "providers": {"goal-test": {
                    "package": "@opencode/ai/providers/openai-compatible",
                    "settings": {"baseURL": f"http://127.0.0.1:{server.server_port}/v1", "apiKey": "test-only"},
                    "models": {"test": {"limit": {"context": 32000, "output": 1000}}},
                }},
            }))

            def api(method, path, body=None):
                args = ["opencode", "api", method, path, "--header", f"x-opencode-directory:{directory}"]
                if body is not None:
                    args += ["--data", json.dumps(body)]
                result = subprocess.run(args, cwd=directory, check=False,
                                        capture_output=True, text=True, timeout=30)
                if result.returncode:
                    raise AssertionError(f"{method} {path}: {result.stdout}\n{result.stderr}")
                if not result.stdout.strip():
                    return None
                payload = json.loads(result.stdout)
                return payload.get("data", payload)

            session = api("post", "/api/session", {
                "title": "Goal auto-continuation integration test",
                "location": {"directory": directory},
                "model": {"providerID": "goal-test", "id": "test"},
            })
            session_id = session["id"]
            try:
                deadline = time.monotonic() + 10
                while True:
                    plugins = api("get", "/api/plugin")
                    if any(p["id"] == "goal" for p in plugins) or time.monotonic() >= deadline:
                        break
                    time.sleep(0.1)
                self.assertTrue(any(p["id"] == "goal" and p["state"]["status"] == "active" for p in plugins),
                                [p for p in plugins if p.get("source", {}).get("type") != "builtin"])
                goal_plugin = next(p for p in plugins if p["id"] == "goal")
                self.assertEqual(goal_plugin["source"]["path"], str(Path.home() / ".goal/opencode/plugin/index.ts"))
                self.assertFalse((project / ".opencode").exists())
                deadline = time.monotonic() + 10
                while True:
                    servers = api("get", "/api/mcp")
                    connected = any(s["name"] == "goal" and s["status"]["status"] == "connected" for s in servers)
                    if connected or time.monotonic() >= deadline:
                        break
                    time.sleep(0.1)
                self.assertTrue(connected, servers)
                skills = api("get", "/api/skill")
                self.assertTrue(any(s["id"] == "goal" for s in skills), skills)
                for arguments in ["Initial test objective", "budget 2"]:
                    subprocess.run(["/bin/bash", str(Path.home() / ".goal/goal_cli.sh"), arguments],
                                   cwd=directory, check=True, capture_output=True, text=True)
                # Test the installed native command with literal shell metacharacters.
                api("post", f"/api/session/{session_id}/command", {
                    "name": "goal", "text": "edit Test continuation $(touch SHOULD_NOT_EXIST)",
                })
                state_file = project / ".claude/goal/goal_state.json"
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    state = json.loads(state_file.read_text())
                    wrapped = any("one final wrap-up" in json.dumps(r["messages"]) for r in requests)
                    if state["status"] == "paused" or (state["status"] == "budget_limited" and wrapped):
                        break
                    time.sleep(0.1)
                api("post", f"/api/experimental/session/{session_id}/wait", {})
                state = json.loads(state_file.read_text())
                self.assertEqual(state["status"], "budget_limited", {
                    "state": state, "session": api("get", f"/api/session/{session_id}/context"),
                    "model_requests": len(requests),
                })
                self.assertEqual(state["turns_used"], 2, state)
                self.assertEqual(state["objective"], "Test continuation $(touch SHOULD_NOT_EXIST)")
                self.assertEqual(state["opencode_session_id"], session_id)
                self.assertFalse((project / "SHOULD_NOT_EXIST").exists())
                transcripts = [json.dumps(request["messages"]) for request in requests]
                self.assertTrue(any("Persistent goal:" in text for text in transcripts))
                self.assertTrue(any("one final wrap-up" in text for text in transcripts))
                self.assertGreaterEqual(len(requests), 3)

                # Stop a real in-flight run and prove the plugin never restarts it.
                for arguments in ["clear", "Test interruption"]:
                    subprocess.run(["/bin/bash", str(Path.home() / ".goal/goal_cli.sh"), arguments],
                                   cwd=directory, check=True, capture_output=True, text=True)
                hold_response.set()
                api("post", f"/api/session/{session_id}/command", {"name": "goal", "text": "status"})
                self.assertTrue(request_started.wait(timeout=5), "model request did not start")
                api("post", f"/api/session/{session_id}/interrupt", {"resume": False})
                release_response.set()
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    state = json.loads(state_file.read_text())
                    if state["status"] == "paused":
                        break
                    time.sleep(0.05)
                self.assertEqual(state["status"], "paused", state)
                api("post", f"/api/experimental/session/{session_id}/wait", {})
                count = len(requests)
                time.sleep(0.2)
                self.assertEqual(len(requests), count, "interruption restarted model generation")
            finally:
                release_response.set()
                api("delete", f"/api/session/{session_id}")


if __name__ == "__main__":
    unittest.main()
