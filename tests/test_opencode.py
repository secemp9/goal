import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("jsonc", ROOT / "src/jsonc.py")
jsonc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(jsonc)


class OpenCodeInstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.project = self.root / "project"
        self.project.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        # Installer tests don't launch the server; isolate prerequisite discovery.
        uv = bin_dir / "uv"
        uv.write_text("#!/bin/sh\nexit 0\n")
        uv.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home),
                        XDG_CONFIG_HOME=str(self.home / ".config"),
                        PATH=f"{bin_dir}:{os.environ['PATH']}")

    def run_script(self, name, check=True, project=True):
        return subprocess.run(
            ["/bin/bash", str(ROOT / name), "--opencode"] + (["--project"] if project else []),
            cwd=self.project, env=self.env, capture_output=True, text=True,
            check=check,
        )

    def test_jsonc_strings_and_trailing_commas(self):
        self.assertEqual(
            jsonc.loads('/* comment */ {"url":"https://host/a//b", '
                        '"text":"literal ,} /*x*/", "list":[1,], // hi\n}'),
            {"url": "https://host/a//b", "text": "literal ,} /*x*/", "list": [1]},
        )

    def test_install_reinstall_and_uninstall(self):
        config = self.project / "opencode.jsonc"
        config.write_text('''{
          // Preserve unrelated native and legacy MCP entries.
          "model": "provider/model",
          "mcp": {
            "goal": {"type":"local", "command":["old"]},
            "other": {"type":"local", "command":["other"]},
            "servers": {"native": {"type":"local", "command":["native"]},},
          },
        }''')
        self.run_script("install.sh")
        first = config.read_text()
        self.run_script("install.sh")
        self.assertEqual(config.read_text(), first)
        data = json.loads(first)
        self.assertEqual(data["model"], "provider/model")
        self.assertIn("other", data["mcp"])
        self.assertIn("native", data["mcp"]["servers"])
        self.assertNotIn("goal", data["mcp"])
        command = data["mcp"]["servers"]["goal"]["command"]
        self.assertEqual(command, [str(self.root / "bin/uv"), "tool", "run", "--from",
                                   str(self.home / ".goal"), "goal-mcp"])
        self.assertTrue((self.home / ".goal/README.md").is_file())
        self.assertFalse((self.project / ".opencode/commands/goal.md").exists())
        self.assertTrue((self.project / ".opencode/plugins/goal/index.ts").is_file())
        skill = (self.project / ".opencode/skills/goal/SKILL.md").read_text()
        self.assertNotIn('!`', skill)
        self.run_script("uninstall.sh")
        data = json.loads(config.read_text())
        self.assertNotIn("goal", data["mcp"]["servers"])
        self.assertIn("native", data["mcp"]["servers"])
        self.assertFalse((self.project / ".opencode/commands/goal.md").exists())
        self.assertFalse((self.project / ".opencode/plugins/goal/index.ts").exists())

    def test_nested_config_preferred_and_global_untouched(self):
        nested = self.project / ".opencode"
        nested.mkdir()
        config = nested / "opencode.jsonc"
        config.write_text('{"mcp":{"servers":{},},}')
        global_dir = self.home / ".config/opencode"
        global_dir.mkdir(parents=True)
        global_config = global_dir / "opencode.json"
        global_config.write_text('{"model":"keep"}')
        self.run_script("install.sh")
        self.assertIn("goal", json.loads(config.read_text())["mcp"]["servers"])
        self.assertEqual(global_config.read_text(), '{"model":"keep"}')
        self.assertFalse((self.project / "opencode.json").exists())

    def test_invalid_config_not_overwritten(self):
        config = self.project / "opencode.jsonc"
        config.write_text('{"broken":')
        result = self.run_script("install.sh", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(config.read_text(), '{"broken":')

    def test_fresh_project_does_not_modify_global_config(self):
        global_dir = self.home / ".config/opencode"
        global_dir.mkdir(parents=True)
        config = global_dir / "opencode.jsonc"
        original = '// global settings\n{"model":"keep",}'
        config.write_text(original)
        self.run_script("install.sh")
        self.assertEqual(config.read_text(), original)
        data = json.loads((self.project / "opencode.json").read_text())
        self.assertIn("goal", data["mcp"]["servers"])

    def test_cli_treats_objective_as_literal(self):
        objective = 'Fix "quotes" and $(touch unwanted) safely'
        subprocess.run(["/bin/bash", str(ROOT / "src/goal_cli.sh"), objective],
                       cwd=self.project, env=self.env, check=True,
                       capture_output=True, text=True)
        state = json.loads((self.project / ".claude/goal/goal_state.json").read_text())
        self.assertEqual(state["objective"], objective)
        self.assertFalse((self.project / "unwanted").exists())

    def test_default_global_install_reinstall_and_uninstall(self):
        config_dir = self.home / ".config/opencode"
        config_dir.mkdir(parents=True)
        config = config_dir / "opencode.jsonc"
        config.write_text('''// global settings
        {"model":"keep", "plugins":["other-plugin"],
         "mcp":{"servers":{"other":{"type":"local","command":["other"]},},},}''')
        project_config = self.project / "opencode.json"
        project_config.write_text('{"model":"project-model"}')
        self.run_script("install.sh", project=False)
        first = config.read_text()
        self.run_script("install.sh", project=False)
        self.assertEqual(config.read_text(), first)
        data = json.loads(first)
        self.assertEqual(data["model"], "keep")
        self.assertIn(str(self.home / ".goal/opencode/plugin"), data["plugins"])
        self.assertIn("other-plugin", data["plugins"])
        self.assertIn("goal", data["mcp"]["servers"])
        self.assertNotIn("cwd", data["mcp"]["servers"]["goal"])
        self.assertNotIn("environment", data["mcp"]["servers"]["goal"])
        self.assertTrue((config_dir / "skills/goal/SKILL.md").is_file())
        self.assertTrue((config_dir / "AGENTS.md").is_file())
        self.assertFalse((self.project / ".opencode").exists())
        self.assertFalse((self.project / "AGENTS.md").exists())
        self.assertEqual(project_config.read_text(), '{"model":"project-model"}')
        self.run_script("uninstall.sh", project=False)
        data = json.loads(config.read_text())
        self.assertNotIn("goal", data["mcp"]["servers"])
        self.assertIn("other", data["mcp"]["servers"])
        self.assertEqual(data["plugins"], ["other-plugin"])
        self.assertFalse((config_dir / "skills/goal/SKILL.md").exists())
        self.assertNotIn("goal-system", (config_dir / "AGENTS.md").read_text())

    def test_global_install_honors_xdg_config_home(self):
        config_dir = self.root / "xdg/opencode"
        self.env["XDG_CONFIG_HOME"] = str(config_dir.parent)
        self.run_script("install.sh", project=False)
        self.assertTrue((config_dir / "opencode.json").is_file())
        self.assertTrue((config_dir / "skills/goal/SKILL.md").is_file())
        self.assertFalse((self.home / ".config/opencode").exists())
        self.run_script("uninstall.sh", project=False)
        self.assertNotIn("goal", json.loads((config_dir / "opencode.json").read_text()).get("mcp", {}).get("servers", {}))

    def test_invalid_global_config_not_overwritten(self):
        config_dir = self.home / ".config/opencode"
        config_dir.mkdir(parents=True)
        config = config_dir / "opencode.jsonc"
        config.write_text('{"broken":')
        result = self.run_script("install.sh", project=False, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(config.read_text(), '{"broken":')


if __name__ == "__main__":
    unittest.main()
