import fs from "node:fs"
import path from "node:path"
import { pathToFileURL } from "node:url"

const CONFIG_SCHEMA = "https://opencode.ai/config.json"
const PLUGIN_PATH = "./tools/agent-output-plugin.mjs"
const POLICY_TEXT = "Never enumerate environment values."
const SENSITIVE_ENV_NAME =
  /(?:^|_)(?:ACCESS_KEY(?:_ID)?|ACCESS_TOKEN|API_?KEY|AUTHORIZATION|CLIENT_SECRET|COOKIE|CREDENTIALS?|GITHUB_PAT|JWT|KEYSTORE_PASSWORD|PASSWORD|PASSWD|PAT|PRIVATE_?KEY|REFRESH_TOKEN|SECRET(?:_KEY)?|SIGNING_KEY|TOKEN)(?:_|$)/i
const SENSITIVE_ENV_EXACT =
  /^(?:BASIC_AUTH|CI_JOB_JWT|DATABASE_URL|DOCKER_AUTH_CONFIG|MAVEN_GPG_KEY|MAVEN_GPG_PASSPHRASE|MYSQL_PWD|NPM_CONFIG__AUTH|PGPASSWORD|STRIPE_ACCOUNT_KEY)$/i
const SENSITIVE_URL_NAME =
  /(?:^|_)(?:(?:AMQP|BROKER|DATABASE|DB|MONGO(?:DB)?|MYSQL|POSTGRES|REDIS)_URL|WEBHOOK_URL)$/i

const PERMISSION_PROBES = [
  "env",
  "/bin/env",
  "/usr/bin/env -0",
  "printenv API_TOKEN",
  "/usr/bin/printenv",
  "set",
  "export",
  "export --",
  "export -p",
  "declare",
  "declare --",
  "declare -p",
  "declare -x",
  "typeset",
  "typeset --",
  "typeset -p",
  "typeset -x",
  "busybox env",
  "adb shell env",
  "adb -s emulator-5554 shell printenv API_TOKEN",
  "/opt/android/adb shell env",
  "xcrun simctl spawn booted env",
  "/usr/bin/xcrun simctl spawn booted launchctl getenv API_TOKEN",
]

const PERMISSION_ALLOW_PROBES = [
  "env FOO=bar ./gradlew test",
  "env -i ./gradlew test",
  "export FOO=bar",
  "declare -x FOO=bar",
  "typeset -x FOO=bar",
]

function shellWords(command) {
  const words = []
  let current = ""
  let quote
  let escaped = false
  let started = false

  for (const char of command) {
    if (escaped) {
      current += char
      escaped = false
      started = true
      continue
    }
    if (char === "\\" && quote !== "'") {
      escaped = true
      started = true
      continue
    }
    if (quote) {
      if (char === quote) quote = undefined
      else current += char
      started = true
      continue
    }
    if (char === "'" || char === '"') {
      quote = char
      started = true
      continue
    }
    if (/\s/.test(char)) {
      if (started) words.push(current)
      current = ""
      started = false
      continue
    }
    current += char
    started = true
  }

  if (escaped) current += "\\"
  if (started) words.push(current)
  return words
}

function extractHeredocs(command) {
  const heredocs = []
  let delimiter
  let currentBody = []
  let executable = ""
  for (const line of command.split("\n")) {
    if (delimiter) {
      if (line.trim() === delimiter) {
        heredocs.push({ executable, body: currentBody.join("\n") })
        currentBody = []
        delimiter = undefined
      } else {
        currentBody.push(line)
      }
      continue
    }
    const match = line.match(/(?:^|\s)([a-zA-Z0-9_.-]+)\s+.*?<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?/)
    if (match) {
      executable = executableName(match[1])
      delimiter = match[2]
    }
  }
  return heredocs
}

function isHeredocDisclosure(exec, body) {
  const isInterp = ["python", "python3", "node", "ruby", "bash", "sh", "zsh", "dash"].includes(exec)
  if (!isInterp) return false
  if (["python", "python3"].includes(exec)) {
    if (/\bos\.environ\b/.test(body) && !/os\.environ(?:\.get)?\s*\(/.test(body)) return true
    if (/\b(?:print|pprint|dump|dumps|items|values)\b.*?\bos\.environ\b/.test(body)) return true
    if (/for\s+.*?\bin\s+os\.environ\b/.test(body)) return true
  }
  if (exec === "node") {
    if (/\bprocess\.env\b/.test(body) && !/process\.env\.[A-Za-z0-9_]+\b/.test(body)) return true
    if (/for\s*\(.*?\bprocess\.env\b/.test(body)) return true
  }
  if (exec === "ruby") {
    if (/\bENV\.(?:each|inspect|to_h|values)\b/.test(body)) return true
  }
  if (["bash", "sh", "zsh", "dash"].includes(exec)) {
    if (/(?:^|[;&|\n])\s*(?:env|printenv|export|declare\s+-p|set)\s*(?:$|[;&|\n])/.test(body)) return true
  }
  return false
}

function stripHeredocBodies(command) {
  const output = []
  let delimiter
  for (const line of command.split("\n")) {
    if (delimiter) {
      if (line.trim() === delimiter) delimiter = undefined
      continue
    }
    output.push(line)
    const match = line.match(/<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?/)
    if (match) delimiter = match[1]
  }
  return output.join("\n")
}

function shellSegments(command) {
  const segments = []
  let current = ""
  let quote
  let escaped = false

  for (const char of stripHeredocBodies(command)) {
    if (escaped) {
      current += char
      escaped = false
      continue
    }
    if (char === "\\" && quote !== "'") {
      current += char
      escaped = true
      continue
    }
    if (quote) {
      current += char
      if (char === quote) quote = undefined
      continue
    }
    if (char === "'" || char === '"') {
      quote = char
      current += char
      continue
    }
    if (";|&()\n".includes(char)) {
      if (current.trim()) segments.push(current)
      current = ""
      continue
    }
    current += char
  }

  if (current.trim()) segments.push(current)
  return segments
}

function executableName(value) {
  return value.replaceAll("\\", "/").split("/").at(-1)
}

function stripsToCommand(words) {
  const result = [...words]
  while (result.length) {
    while (result[0]?.match(/^[A-Za-z_][A-Za-z0-9_]*=/)) result.shift()
    const executable = executableName(result[0] ?? "")
    if (["{", "command", "builtin", "eval", "exec", "nohup"].includes(executable)) {
      result.shift()
      if (result[0] === "--") result.shift()
      continue
    }
    if (executable === "time") {
      result.shift()
      while (result[0]?.startsWith("-")) {
        const option = result.shift()
        if (["-f", "--format", "-o", "--output"].includes(option)) result.shift()
      }
      continue
    }
    break
  }
  return result
}

function envCommandIsUnsafe(words, depth) {
  let index = 1
  let clean = false
  let assigned = false

  while (index < words.length) {
    const word = words[index]
    if (word === "--") {
      index++
      break
    }
    if (word === "-i" || word === "--ignore-environment") {
      clean = true
      index++
      continue
    }
    if (word === "-0" || word === "--null") {
      index++
      continue
    }
    if (word === "-u" || word === "--unset" || word === "-C" || word === "--chdir") {
      index += 2
      continue
    }
    if (word.startsWith("--unset=") || word.startsWith("--chdir=")) {
      index++
      continue
    }
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(word)) {
      assigned = true
      index++
      continue
    }
    break
  }

  if (words[index]) return unsafeWords(words.slice(index), depth + 1)
  return !clean || assigned
}

function sshCommand(words) {
  const valueOptions = new Set([
    "-b",
    "-c",
    "-D",
    "-E",
    "-e",
    "-F",
    "-I",
    "-i",
    "-J",
    "-L",
    "-l",
    "-m",
    "-O",
    "-o",
    "-p",
    "-Q",
    "-R",
    "-S",
    "-W",
    "-w",
  ])
  let index = 1
  while (index < words.length) {
    const word = words[index]
    if (word === "--") {
      index++
      break
    }
    if (!word.startsWith("-")) break
    index += valueOptions.has(word) ? 2 : 1
  }
  return words.slice(index + 1)
}

function dockerExecCommand(words) {
  const exec = words.indexOf("exec", 1)
  if (exec < 0) return []
  const valueOptions = new Set([
    "-e",
    "--env",
    "--env-file",
    "-u",
    "--user",
    "-w",
    "--workdir",
    "--detach-keys",
  ])
  let index = exec + 1
  while (index < words.length && words[index].startsWith("-")) {
    const word = words[index]
    index += word.includes("=") || !valueOptions.has(word) ? 1 : 2
  }
  return words.slice(index + 1)
}

function kubectlExecCommand(words) {
  const exec = words.indexOf("exec", 1)
  if (exec < 0) return []
  const separator = words.indexOf("--", exec + 1)
  if (separator >= 0) return words.slice(separator + 1)
  const target = words.findIndex((word, index) => index > exec && !word.startsWith("-"))
  return target >= 0 ? words.slice(target + 1) : []
}

function unsafeWords(input, depth) {
  const words = stripsToCommand(input)
  if (!words.length) return false

  const executable = executableName(words[0])
  const lowerExecutable = executable.toLowerCase()
  if (executable === "env") return envCommandIsUnsafe(words, depth)
  if (executable === "printenv") return true
  if (executable === "busybox" && words[1]) return unsafeWords(words.slice(1), depth + 1)
  if (executable === "set") return words.length === 1 || /^\d*[<>]/.test(words[1])
  if (executable === "export") {
    const operands = words.slice(1).filter((word) => word !== "--")
    return operands.length === 0 || operands.some((word) => word === "-p" || word.startsWith("-p"))
  }

  if (executable === "declare" || executable === "typeset") {
    const options = words.slice(1).filter((word) => word.startsWith("-") && word !== "--")
    const operands = words
      .slice(1)
      .filter((word) => word !== "--" && !word.startsWith("-") && !/^\d*[<>]/.test(word))
    if (operands.length === 0 && options.length === 0) return true
    if (options.some((word) => word.includes("p"))) return true
    if (options.some((word) => word.includes("x")) && operands.length === 0) return true
  }

  if (executable === "sudo") {
    return words.slice(1).some((word, index, rest) => {
      const candidate = executableName(word)
      if (!["env", "printenv"].includes(candidate)) return false
      return unsafeWords(rest.slice(index), depth + 1)
    })
  }

  if (executable === "adb") {
    const shell = words.indexOf("shell", 1)
    if (shell >= 0) return unsafeWords(words.slice(shell + 1), depth + 1)
  }

  if (executable === "xcrun" && words[1] === "simctl") {
    const spawn = words.indexOf("spawn", 2)
    if (spawn >= 0 && words[spawn + 2]) return unsafeWords(words.slice(spawn + 2), depth + 1)
  }

  if (executable === "launchctl" && words[1] === "getenv") return true

  if (executable === "ssh") return unsafeWords(sshCommand(words), depth + 1)
  if (executable === "docker") return unsafeWords(dockerExecCommand(words), depth + 1)
  if (executable === "kubectl") return unsafeWords(kubectlExecCommand(words), depth + 1)

  if (["get-childitem", "get-item", "gci", "gi"].includes(lowerExecutable)) {
    return words.slice(1).some((word) => /^env:/i.test(word))
  }

  if (["powershell", "pwsh"].includes(lowerExecutable)) {
    const command = words.findIndex((word) => ["-c", "-command"].includes(word.toLowerCase()))
    if (command >= 0 && words[command + 1]) return isEnvironmentDisclosure(words[command + 1], depth + 1)
  }

  if (executable === "jq" && words.slice(1).some((word) => ["env", "$ENV"].includes(word.trim()))) return true

  if (["bash", "dash", "sh", "zsh"].includes(executable)) {
    const command = words.findIndex((word) => /^-[A-Za-z]*c[A-Za-z]*$/.test(word) || word === "--command")
    if (command >= 0 && words[command + 1]) return isEnvironmentDisclosure(words[command + 1], depth + 1)
  }

  if (["python", "python3"].includes(executable)) {
    const command = words.indexOf("-c")
    const code = words[command + 1] ?? ""
    if (command >= 0) {
      if (
        /(?:print|pprint)\s*\(\s*(?:dict\s*\(\s*)?os\.environ\b/.test(code) ||
        /os\.environ\.(?:items|values)\s*\(/.test(code) ||
        /json\.dumps\s*\(\s*(?:dict\s*\(\s*)?os\.environ\b/.test(code) ||
        /for\s+.*?\bin\s+os\.environ\b/.test(code) ||
        /\[.*?for\s+.*?\bin\s+os\.environ\b/.test(code)
      )
        return true
    }
  }

  if (executable === "node") {
    const command = words.findIndex((word) => ["-e", "--eval", "-p", "--print"].includes(word))
    const code = words[command + 1] ?? ""
    if (command >= 0) {
      if (
        /console\.(?:dir|log)\s*\(\s*process\.env\s*\)/.test(code) ||
        /JSON\.stringify\s*\(\s*process\.env\b/.test(code) ||
        /Object\.(?:entries|values|keys)\s*\(\s*process\.env\s*\)/.test(code) ||
        /for\s*\(.*?\bprocess\.env\b/.test(code) ||
        (["-p", "--print"].includes(words[command]) && /^process\.env$/.test(code.trim()))
      )
        return true
    }
  }

  if (executable === "ruby") {
    const command = words.indexOf("-e")
    const code = words[command + 1] ?? ""
    if (
      command >= 0 &&
      (/(?:^|[;\s])(?:p|print|puts)\s+ENV(?:\.(?:inspect|to_h))?(?=\s*(?:;|$))/.test(code) ||
        /\bENV\.(?:each|inspect|to_h)\b/.test(code))
    )
      return true
  }

  return false
}

export function isEnvironmentDisclosure(command, depth = 0) {
  if (typeof command !== "string" || depth > 4) return false
  if (/\/proc\/(?:self|\d+|\$\$)\/environ(?=["'\s]|$)/.test(command)) return true
  const heredocs = extractHeredocs(command)
  if (heredocs.some(({ executable, body }) => isHeredocDisclosure(executable, body))) return true
  return shellSegments(command).some((segment) => unsafeWords(shellWords(segment), depth))
}

export function redactCanaryOutput(text, canaryValues = []) {
  if (typeof text !== "string") return text
  for (const canary of canaryValues) {
    if (canary && text.includes(canary)) {
      throw new Error("Blocked environment-value output. Sensitive canary value leaked in tool output.")
    }
  }
  return text
}

export function scrubSensitiveEnvironment(output, environment = process.env) {
  for (const [name, value] of Object.entries(environment)) {
    if (value === undefined) continue
    if (!SENSITIVE_ENV_NAME.test(name) && !SENSITIVE_ENV_EXACT.test(name) && !SENSITIVE_URL_NAME.test(name)) continue
    output[name] = ""
  }
  return output
}

export function wildcardMatch(input, pattern) {
  let escaped = pattern
    .replaceAll("\\", "/")
    .replace(/[.+^${}()|[\]\\]/g, "\\$&")
    .replace(/\*/g, ".*")
    .replace(/\?/g, ".")
  if (escaped.endsWith(" .*")) escaped = `${escaped.slice(0, -3)}( .*)?`
  return new RegExp(`^${escaped}$`, "s").test(input.replaceAll("\\", "/"))
}

export function evaluateBashPolicy(config, command) {
  const rules = config?.permission?.bash
  if (typeof rules === "string") return rules
  if (!rules || typeof rules !== "object" || Array.isArray(rules)) return "ask"
  return Object.entries(rules).reduce(
    (action, [pattern, next]) => (wildcardMatch(command, pattern) ? next : action),
    "ask",
  )
}

export function validatePolicyConfig(config) {
  const errors = []
  if (config?.$schema !== CONFIG_SCHEMA) errors.push(`opencode.json must declare ${CONFIG_SCHEMA}`)

  const plugins = Array.isArray(config?.plugin) ? config.plugin : []
  const hasPlugin = plugins.some((entry) => (Array.isArray(entry) ? entry[0] : entry) === PLUGIN_PATH)
  if (!hasPlugin) errors.push(`opencode.json must load ${PLUGIN_PATH}`)

  for (const command of PERMISSION_PROBES) {
    if (evaluateBashPolicy(config, command) !== "deny") errors.push(`bash policy must deny: ${command}`)
  }
  for (const command of PERMISSION_ALLOW_PROBES) {
    if (evaluateBashPolicy(config, command) === "deny") errors.push(`bash policy must allow: ${command}`)
  }
  return errors
}

export function checkProjectPolicy(root = process.cwd()) {
  const configPath = path.join(root, "opencode.json")
  const config = JSON.parse(fs.readFileSync(configPath, "utf8"))
  const errors = validatePolicyConfig(config)
  if (!fs.existsSync(path.join(root, PLUGIN_PATH))) errors.push(`missing plugin: ${PLUGIN_PATH}`)

  const instructions = fs.readFileSync(path.join(root, "CLAUDE.md"), "utf8")
  if (!instructions.includes(POLICY_TEXT)) errors.push(`CLAUDE.md must include: ${POLICY_TEXT}`)
  if (errors.length) throw new Error(errors.join("\n"))
}

const invokedPath = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : undefined
if (invokedPath === import.meta.url) {
  try {
    checkProjectPolicy()
    console.log("agent output policy: passed")
  } catch (error) {
    console.error(`agent output policy: ${error.message}`)
    process.exitCode = 1
  }
}
