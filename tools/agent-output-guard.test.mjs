import assert from "node:assert/strict"
import fs from "node:fs"
import path from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

import * as pluginModule from "./agent-output-plugin.mjs"
import { AgentOutputGuard } from "./agent-output-plugin.mjs"
import {
  checkProjectPolicy,
  isEnvironmentDisclosure,
  scrubSensitiveEnvironment,
  validatePolicyConfig,
} from "./agent-output-guard.mjs"

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")

test("plugin exposes exactly one function for the OpenCode 1.18 loader", () => {
  assert.deepEqual(Object.keys(pluginModule), ["AgentOutputGuard"])
  assert.equal(typeof pluginModule.AgentOutputGuard, "function")
})

test("blocks direct, remote, wrapped, and scripted environment disclosure", () => {
  const blocked = [
    "env",
    "env | sort",
    "FOO=bar /usr/bin/env",
    "printenv API_TOKEN",
    "set",
    "set > captured.txt",
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
    "jq -n env",
    "jq -n '$ENV'",
    "command env",
    "command -- env",
    "exec /usr/bin/env",
    "time -p env",
    "sudo -u root env",
    "echo ready && env | sort",
    "adb shell env",
    "adb -s emulator-5554 shell printenv API_TOKEN",
    "xcrun simctl spawn booted env",
    "xcrun simctl spawn booted launchctl getenv API_TOKEN",
    "ssh example.test env",
    "ssh -p 2222 example.test printenv API_TOKEN",
    "docker exec app env",
    "docker exec -u root app printenv API_TOKEN",
    "kubectl exec pod -- env",
    "kubectl exec pod printenv API_TOKEN",
    "Get-ChildItem Env:",
    "gci Env:API_TOKEN",
    "pwsh -Command 'Get-Item Env:API_TOKEN'",
    "bash -lc 'env | sort'",
    "bash -c 'eval env'",
    "sh -c \"printenv API_TOKEN\"",
    "python3 -c 'import os; print(dict(os.environ))'",
    "node -e 'console.log(process.env)'",
    "node -p process.env",
    "ruby -e 'puts ENV.inspect'",
    "ruby -e 'p ENV'",
    "tr '\\0' '\\n' < /proc/self/environ",
    "cat \"/proc/self/environ\"",
    "python3 - <<'PY'\nimport os\nprint(dict(os.environ))\nPY",
    "node -e 'for (let k in process.env) console.log(k, process.env[k])'",
    "python3 -c 'for k, v in os.environ.items(): print(k, v)'",
  ]

  for (const command of blocked) assert.equal(isEnvironmentDisclosure(command), true, command)
})

test("allows environment setup and targeted presence checks that emit no values", () => {
  const allowed = [
    "FOO=bar ./gradlew test",
    "env FOO=bar ./gradlew test",
    "env -i ./gradlew test",
    "command -- git status",
    "export FOO=bar",
    "set -euo pipefail",
    "declare -x FOO=bar",
    "typeset -x FOO=bar",
    "test -n \"${API_TOKEN:-}\" && printf 'API_TOKEN=set\\n'",
    "adb shell getprop ro.build.version.sdk",
    "xcrun simctl spawn booted defaults read com.example.app enabled",
    "printf '%s\\n' 'env'",
    "python3 -c 'import os; print(\"API_TOKEN=set\" if \"API_TOKEN\" in os.environ else \"API_TOKEN=unset\")'",
    "python3 -c 'import os; print(\"API_TOKEN=set\" if os.getenv(\"API_TOKEN\") else \"API_TOKEN=unset\")'",
    "node -e 'console.log(process.env.API_TOKEN ? \"API_TOKEN=set\" : \"API_TOKEN=unset\")'",
    "ruby -e 'puts ENV.key?(\"API_TOKEN\") ? \"API_TOKEN=set\" : \"API_TOKEN=unset\"'",
    "cat <<'EOF'\nenv\nexport\nEOF",
  ]

  for (const command of allowed) assert.equal(isEnvironmentDisclosure(command), false, command)
})

test("clears inherited sensitive values without breaking SSH or ordinary settings", () => {
  const environment = {
    HOP_TEST_API_TOKEN: "hop-test-canary-value-123",
    PGPASSWORD: "short",
    MYSQL_PWD: "mysql-secret",
    DATABASE_URL: "postgres://user:secret@example.test/db",
    DOCKER_AUTH_CONFIG: "docker-auth-json",
    NPM_CONFIG__AUTH: "npm-basic-auth",
    BASIC_AUTH: "basic-auth-value",
    CI_JOB_JWT: "ci-job-jwt-value",
    POSTGRES_URL: "postgres://user:secret@example.test/db",
    MYSQL_URL: "mysql://user:secret@example.test/db",
    SLACK_WEBHOOK_URL: "https://hooks.example.test/secret",
    GITHUB_PAT: "github-personal-access-token",
    STRIPE_ACCOUNT_KEY: "stripe-account-secret",
    MAVEN_GPG_KEY: "maven-gpg-private-key",
    MAVEN_GPG_PASSPHRASE: "maven-gpg-passphrase",
    SSH_AUTH_SOCK: "/tmp/ssh-agent.sock",
    ORDINARY_SETTING: "ordinary-visible-value",
  }
  const output = { EXPLICIT_SETTING: "kept" }
  scrubSensitiveEnvironment(output, environment)
  assert.deepEqual(output, {
    EXPLICIT_SETTING: "kept",
    HOP_TEST_API_TOKEN: "",
    PGPASSWORD: "",
    MYSQL_PWD: "",
    DATABASE_URL: "",
    DOCKER_AUTH_CONFIG: "",
    NPM_CONFIG__AUTH: "",
    BASIC_AUTH: "",
    CI_JOB_JWT: "",
    POSTGRES_URL: "",
    MYSQL_URL: "",
    SLACK_WEBHOOK_URL: "",
    GITHUB_PAT: "",
    STRIPE_ACCOUNT_KEY: "",
    MAVEN_GPG_KEY: "",
    MAVEN_GPG_PASSPHRASE: "",
  })
})

test("plugin blocks before execution and scrubs the child environment", async () => {
  const environment = {
    HOP_TEST_API_TOKEN: "hop-test-plugin-canary-456",
    SSH_AUTH_SOCK: "/tmp/ssh-agent.sock",
    ORDINARY_SETTING: "ordinary-visible-value",
  }
  const hooks = await AgentOutputGuard({}, { environment })
  await assert.rejects(
    hooks["tool.execute.before"]({ tool: "bash" }, { args: { command: "env | sort" } }),
    /Blocked environment-value output/,
  )
  await hooks["tool.execute.before"]({ tool: "bash" }, { args: { command: "API_TOKEN=set ./gradlew test" } })

  const output = { env: { EXPLICIT_SETTING: "kept" } }
  await hooks["shell.env"]({}, output)
  assert.deepEqual(output.env, { EXPLICIT_SETTING: "kept", HOP_TEST_API_TOKEN: "" })
})
test("plugin redacts leaked canary values in tool output", async () => {
  const canary = "hop-secret-canary-789"
  const environment = { HOP_TEST_CANARY: canary }
  const hooks = await AgentOutputGuard({}, { environment, canaries: [canary] })
  await assert.rejects(
    hooks["tool.execute.after"]({ tool: "bash" }, { result: `Output contained ${canary}` }),
    /Sensitive canary value leaked in tool output/,
  )
  await assert.doesNotThrow(async () => {
    await hooks["tool.execute.after"]({ tool: "bash" }, { result: "NAME=set" })
  })
})


test("checked-in OpenCode policy loads the plugin and denies direct probes", () => {
  assert.doesNotThrow(() => checkProjectPolicy(root))

  const config = JSON.parse(fs.readFileSync(path.join(root, "opencode.json"), "utf8"))
  config.permission.bash["*"] = "allow"
  assert.match(validatePolicyConfig(config).join("\n"), /bash policy must deny/)
})
