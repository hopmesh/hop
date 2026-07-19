import { isEnvironmentDisclosure, scrubSensitiveEnvironment } from "./agent-output-guard.mjs"

export const AgentOutputGuard = async (_input, options = {}) => {
  const environment = options.environment ?? process.env
  return {
    "tool.execute.before": async (input, output) => {
      if (input.tool !== "bash") return
      if (isEnvironmentDisclosure(output?.args?.command)) {
        throw new Error("Blocked environment-value output. Check named variables and report only set or unset.")
      }
    },
    "shell.env": async (_input, output) => {
      scrubSensitiveEnvironment(output.env, environment)
    },
  }
}
