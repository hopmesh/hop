import {
  isEnvironmentDisclosure,
  loadOpencodeAllowlist,
  loadOpencodeEnvironmentMode,
  redactCanaryOutput,
  scrubSensitiveEnvironment,
} from "./agent-output-guard.mjs"

export const AgentOutputGuard = async (_input, options = {}) => {
  const environment = options.environment ?? process.env
  const canaries = options.canaries ?? Object.values(environment).filter((v) => typeof v === "string" && v.length > 8)
  const mode = options.mode ?? loadOpencodeEnvironmentMode()
  const allowlist = options.allowlist ?? loadOpencodeAllowlist()
  return {
    "tool.execute.before": async (input, output) => {
      if (input.tool !== "bash") return
      if (isEnvironmentDisclosure(output?.args?.command)) {
        throw new Error("Blocked environment-value output. Check named variables and report only set or unset.")
      }
    },
    "shell.env": async (_input, output) => {
      scrubSensitiveEnvironment(output.env, environment, { mode, allowlist })
    },
    "tool.execute.after": async (input, output) => {
      if (input.tool !== "bash") return
      const text = typeof output?.result === "string" ? output.result : typeof output?.output === "string" ? output.output : ""
      redactCanaryOutput(text, canaries)
    },
  }
}
