import { execFile } from "node:child_process"
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join, resolve } from "node:path"
import { promisify } from "node:util"

const exec = promisify(execFile)

export function createGoalRuntime(ctx, options = {}) {
  const directory = ctx.location.directory
  const stateFile = options.stateFile ?? join(directory, ".claude/goal/goal_state.json")
  const now = options.now ?? Date.now
  const running = new Map()
  let disposed = false

  function read() {
    try {
      const state = JSON.parse(readFileSync(stateFile, "utf8"))
      return state?.goal_id ? state : undefined
    } catch (error) {
      if (error.code === "ENOENT") return undefined
      // Corrupt state must stop continuation, not silently become a new goal.
      throw error
    }
  }

  function write(state) {
    mkdirSync(dirname(stateFile), { recursive: true })
    const temporary = `${stateFile}.tmp.${process.pid}.opencode`
    writeFileSync(temporary, `${JSON.stringify(state, null, 2)}\n`)
    renameSync(temporary, stateFile)
  }

  async function eligible(sessionID) {
    const session = await ctx.session.get({ sessionID })
    return !session.parentID && resolve(session.location.directory) === resolve(directory)
  }

  async function context(event) {
    if (disposed || !(await eligible(event.sessionID))) return
    const state = read()
    if (!state || state.status !== "active") return
    if (state.opencode_session_id && state.opencode_session_id !== event.sessionID) return
    if (!state.opencode_session_id) {
      state.opencode_session_id = event.sessionID
      write(state)
    }
    const current = running.get(event.sessionID)
    if (current?.goalID !== state.goal_id) {
      running.set(event.sessionID, { goalID: state.goal_id, started: now() })
    }
    const remaining = state.turn_budget == null ? "unlimited" : Math.max(0, state.turn_budget - state.turns_used)
    event.system.push({ type: "text", text:
      `Persistent goal: ${state.objective}\nTurns remaining: ${remaining}. ` +
      "Keep working toward every requirement. Before marking complete, inspect authoritative " +
      "evidence for each requirement and use goal update_goal with status complete only when all are met. " +
      "Do not redefine success or mark complete just to stop. Ask the user when blocked."
    })
  }

  async function terminal(event) {
    if (disposed) return
    // Also filter locally: early V2 hosts may not apply subscription filters.
    if (!["session.execution.succeeded", "session.execution.failed", "session.execution.interrupted"].includes(event.type)) return
    const sessionID = event.data.sessionID
    const execution = running.get(sessionID)
    running.delete(sessionID)
    if (!execution) return
    const state = read()
    if (!state || state.goal_id !== execution.goalID || state.opencode_session_id !== sessionID) return
    if (state.opencode_last_event === event.id) return
    state.opencode_last_event = event.id
    state.time_used_seconds += Math.max(0, Math.floor((now() - execution.started) / 1000))
    state.updated_at = new Date(now()).toISOString()

    if (event.type !== "session.execution.succeeded") {
      // A user stop or failure must never be counteracted with another prompt.
      if (state.status === "active") state.status = "paused"
      write(state)
      return
    }
    state.turns_used += 1
    let wrapUp = false
    if (state.status === "active" && state.turn_budget != null && state.turns_used >= state.turn_budget) {
      state.status = "budget_limited"
      wrapUp = true
    }
    write(state)
    if (state.status !== "active" && !wrapUp) return
    if (disposed || !(await eligible(sessionID))) return
    // Re-read after async calls: pause/clear/complete/replace may have happened.
    const latest = read()
    if (!latest || latest.goal_id !== state.goal_id || latest.status !== state.status ||
        latest.opencode_session_id !== sessionID) return
    await ctx.session.prompt({
      sessionID,
      delivery: "queue",
      metadata: { goal: state.goal_id, source: "goal-continuation" },
      text: wrapUp
        ? `The goal turn budget (${state.turn_budget}) has been reached. Do not start new work. ` +
          "Give one final wrap-up: completed work, evidence, remaining requirements, and blockers. " +
          "Do not mark the goal complete unless every requirement is actually satisfied."
        : `Continue working toward the persistent goal: ${state.objective}\n` +
          `Turns used: ${state.turns_used}; budget: ${state.turn_budget ?? "unlimited"}. ` +
          "Take the next concrete step. Verify all requirements before marking complete with update_goal. " +
          "If blocked on user input, explain the blocker and ask the user to /goal pause.",
    })
  }

  async function command({ sessionID, prompt, delivery }) {
    if (!(await eligible(sessionID))) throw new Error("/goal requires a root session in this project")
    const args = prompt.text.trim()
    const { stdout, stderr } = await exec("/bin/bash", [join(homedir(), ".goal/goal_cli.sh"), args], {
      cwd: directory,
      env: { ...process.env, GOAL_STATE_FILE: stateFile },
    })
    const state = read()
    if (state?.status === "active" && args) {
      // An explicit user command may transfer ownership to another root session.
      state.opencode_session_id = sessionID
      write(state)
    }
    await ctx.session.prompt({
      ...prompt, sessionID, delivery,
      text: `The /goal CLI has already executed the requested operation. Report this result; ` +
        `do not repeat the state change.\n\n${stdout}${stderr}`,
    })
  }

  return { context, terminal, command, dispose() { disposed = true; running.clear() } }
}

export async function setupGoal(ctx) {
  const runtime = createGoalRuntime(ctx)
  const controller = new AbortController()
  await ctx.session.hook("context", runtime.context)
  await ctx.command.transform((editor) => editor.add({
    name: "goal",
    description: "Set, view, pause, resume, edit, budget, or clear a persistent goal",
    execute: runtime.command,
  }))
  const events = ctx.event.subscribe({
    types: ["session.execution.succeeded", "session.execution.failed", "session.execution.interrupted"],
    signal: controller.signal,
  })
  const watcher = (async () => {
    for await (const event of events) {
      try { await runtime.terminal(event) }
      catch (error) { console.error("goal: continuation stopped", error) }
    }
  })().catch((error) => {
    if (!controller.signal.aborted) console.error("goal: event subscription stopped", error)
  })
  return async () => { runtime.dispose(); controller.abort(); await watcher }
}
