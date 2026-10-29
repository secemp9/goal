import { afterEach, beforeEach, describe, expect, test } from "bun:test"
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { createGoalRuntime } from "../src/opencode/plugin/runtime.mjs"

describe("OpenCode goal continuation", () => {
  let directory, stateFile, ctx, runtime, clock, prompts
  const state = () => JSON.parse(readFileSync(stateFile, "utf8"))
  const write = (value) => writeFileSync(stateFile, JSON.stringify(value))
  const context = (sessionID = "root") => runtime.context({ sessionID, system: [] })
  const end = (type = "succeeded", id = "terminal-1", sessionID = "root") =>
    runtime.terminal({ id, type: `session.execution.${type}`, data: { sessionID, reason: "user" } })

  beforeEach(() => {
    directory = mkdtempSync(join(tmpdir(), "goal-runtime-"))
    stateFile = join(directory, "state.json")
    clock = 1000
    prompts = []
    write({ goal_id: "goal-1", objective: "Prove all requirements", status: "active",
      turns_used: 0, time_used_seconds: 0, turn_budget: null })
    ctx = {
      location: { directory },
      session: {
        get: async ({ sessionID }) => ({ location: { directory }, ...(sessionID === "child" ? { parentID: "root" } : {}) }),
        prompt: async (prompt) => { prompts.push(prompt) },
      },
    }
    runtime = createGoalRuntime(ctx, { stateFile, now: () => clock })
  })
  afterEach(() => { runtime.dispose(); rmSync(directory, { recursive: true, force: true }) })

  test("continues once per successful busy period, not per model/tool step", async () => {
    await context()
    await context()
    await runtime.terminal({ id: "step", type: "session.step.ended", data: { sessionID: "root" } })
    clock = 4500
    await end()
    await end()
    expect(state().turns_used).toBe(1)
    expect(state().time_used_seconds).toBe(3)
    expect(prompts).toHaveLength(1)
    expect(prompts[0].delivery).toBe("queue")
  })

  test("budget exhaustion gives exactly one wrap-up", async () => {
    write({ ...state(), turn_budget: 1 })
    await context()
    await end()
    expect(state().status).toBe("budget_limited")
    expect(prompts).toHaveLength(1)
    expect(prompts[0].text).toContain("one final wrap-up")
    await context()
    await end("succeeded", "terminal-2")
    expect(prompts).toHaveLength(1)
  })

  for (const status of ["paused", "complete", "budget_limited"]) {
    test(`does not continue when goal becomes ${status}`, async () => {
      await context()
      write({ ...state(), status })
      await end()
      expect(state().status).toBe(status)
      expect(prompts).toHaveLength(0)
    })
  }

  for (const result of ["interrupted", "failed"]) {
    test(`${result} pauses instead of restarting`, async () => {
      await context()
      await end(result)
      expect(state().status).toBe("paused")
      expect(prompts).toHaveLength(0)
    })
  }

  test("children and other locations cannot claim the goal", async () => {
    await context("child")
    expect(state().opencode_session_id).toBeUndefined()
    ctx.session.get = async () => ({ location: { directory: "/elsewhere" } })
    await context()
    expect(state().opencode_session_id).toBeUndefined()
  })

  test("other root sessions cannot steal an owned goal", async () => {
    await context()
    await context("other")
    await end("succeeded", "other-terminal", "other")
    expect(state().opencode_session_id).toBe("root")
    expect(prompts).toHaveLength(0)
  })

  test("cleared and replaced goals cannot be revived", async () => {
    await context()
    write({ ...state(), goal_id: "replacement" })
    await end()
    expect(state().turns_used).toBe(0)
    expect(prompts).toHaveLength(0)
    await context()
    write({})
    await end("succeeded", "terminal-2")
    expect(prompts).toHaveLength(0)
  })

  test("pause during asynchronous session lookup cancels continuation", async () => {
    await context()
    ctx.session.get = async () => {
      write({ ...state(), status: "paused" })
      return { location: { directory } }
    }
    await end()
    expect(prompts).toHaveLength(0)
  })

  test("unload does not restart work", async () => {
    await context()
    runtime.dispose()
    await end()
    expect(prompts).toHaveLength(0)
  })
})
