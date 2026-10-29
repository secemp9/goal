"""Run with: uv run --python 3.12 --with . python tests/test_mcp.py"""

import json
import os
import sys
import tempfile
import unittest

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


class MCPIntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def test_stdio_goal_lifecycle(self):
        with tempfile.TemporaryDirectory() as project:
            params = StdioServerParameters(
                command=sys.executable,
                args=["-m", "goal_mcp.server"],
                cwd=project,
                env={key: value for key, value in os.environ.items()
                     if key not in {"GOAL_STATE_FILE", "CLAUDE_PROJECT_DIR"}},
            )
            async with stdio_client(params) as (reader, writer):
                async with ClientSession(reader, writer) as client:
                    await client.initialize()
                    catalog = await client.list_tools()
                    self.assertEqual({tool.name for tool in catalog.tools},
                                     {"get_goal", "create_goal", "update_goal"})
                    result = await client.call_tool("get_goal", {})
                    self.assertIsNone(json.loads(result.content[0].text)["goal"])
                    result = await client.call_tool("create_goal", {
                        "objective": "Verify OpenCode integration", "turn_budget": 3,
                    })
                    self.assertFalse(result.isError)
                    goal = json.loads(result.content[0].text)["goal"]
                    self.assertEqual(goal["status"], "active")
                    result = await client.call_tool("create_goal", {"objective": "duplicate"})
                    self.assertTrue(result.isError)
                    result = await client.call_tool("update_goal", {"status": "complete"})
                    self.assertFalse(result.isError)
                    self.assertEqual(json.loads(result.content[0].text)["goal"]["status"],
                                     "complete")
                    with open(os.path.join(project, ".claude/goal/goal_state.json")) as f:
                        self.assertEqual(json.load(f)["status"], "complete")


if __name__ == "__main__":
    unittest.main()
