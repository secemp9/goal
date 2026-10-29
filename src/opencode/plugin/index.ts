import { Plugin } from "@opencode/plugin"
import { setupGoal } from "./runtime.mjs"

export default Plugin.define({ id: "goal", setup: setupGoal })
