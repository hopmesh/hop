export const meta = {
  name: 'ble-dual-role-implement',
  description: 'Implement the minimal dual-role BLE transport on both platforms from SPEC.md, verify each compiles, audit cross-platform wire compatibility, fix',
  phases: [
    { title: 'Implement' },
    { title: 'WireAudit' },
    { title: 'Fix' },
  ],
}

const ROOT = 'apps/ble-lab'

const BUILD_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['platform', 'built', 'buildCmd', 'artifactPath', 'entryPoints', 'logFormat', 'notes'],
  properties: {
    platform: { type: 'string', enum: ['android', 'apple'] },
    built: { type: 'boolean', description: 'true ONLY if the build command actually succeeded end-to-end' },
    buildCmd: { type: 'string', description: 'the exact shell command that builds it' },
    artifactPath: { type: 'string', description: 'path to the built apk / binary' },
    entryPoints: { type: 'string', description: 'how to install/run it (adb install + am start, or run the binary); package/bundle id' },
    logFormat: { type: 'string', description: 'what log tag/prefix it emits and the key lines that signal channel-up, bytes-flowing, link-down' },
    notes: { type: 'string', description: 'anything the test driver must know; honest about what is NOT yet working' },
  },
}

const ANDROID = `Read the canonical spec at ${ROOT}/SPEC.md (Read tool) in full. Implement the COMPLETE minimal Android (Kotlin) dual-role BLE app under ${ROOT}/android exactly as the spec dictates. It must be a fresh, standalone, buildable project with a NEW package id (e.g. sh.hopme.blelab) so it does not collide with any existing app on the device. To avoid fighting the toolchain, model your gradle wrapper / AGP / SDK config on the KNOWN-GOOD project at apps/android/HopDemo (copy/adapt its gradle infra; do NOT import its app source). Use JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home for gradle. The app must: run the symmetric dual role, log every state transition with a clear grep-able prefix (e.g. [HOPLOG]), support scanning while advertising, connect to an identical peer, send 10 echo packets back and forth, and log PROOF: <bytes> on completion. Output schema: return the exact commands to build and run it.`

const APPLE = `Read the canonical spec at ${ROOT}/SPEC.md (Read tool) in full. Implement the COMPLETE minimal Apple (Swift / CoreBluetooth) dual-role BLE program under ${ROOT}/apple exactly as the spec dictates, with a NEW bundle/service scheme that does not collide with existing apps. PRIMARY build target: a native macOS CoreBluetooth command-line program that compiles with swiftc and logs to stdout (model the swiftc invocation on the known-good apps/apple/hopmac/build.sh, but this PoC needs NO Rust/hop-ffi, pure CoreBluetooth). Structure the BLE logic in a SHARED core .swift file so it can later be wrapped in a minimal iOS app target with no logic changes; provide a build script. The program must run the symmetric dual role, scan while advertising the custom 128-bit service UUID, connect to an Android peer running the Kotlin app, negotiate MTU, exchange 10 packets, and log PROOF: <bytes>. Output schema: return buildCmd and artifactPath.`

phase('Implement')
const builds = (await parallel([
  () => agent(ANDROID, { label: 'impl:android', phase: 'Implement', schema: BUILD_SCHEMA }),
  () => agent(APPLE, { label: 'impl:apple', phase: 'Implement', schema: BUILD_SCHEMA }),
])).filter(Boolean)

log(`builds: ${builds.map(b => `${b.platform}=${b.built}`).join(', ')}`)

phase('WireAudit')
const audit = await agent(
  `You are auditing CROSS-PLATFORM WIRE COMPATIBILITY between two independent implementations of the same BLE transport spec. Read: ${ROOT}/SPEC.md, the Android source under ${ROOT}/android, and the Apple source under ${ROOT}/apple (use Read/Grep/Glob).\n\n` +
  `The #1 cause of cross-platform BLE failure is the two sides disagreeing on the EXACT bytes/order. Verify they match EXACTLY: service + characteristic UUIDs; advertisement layout (every byte, endianness, manufacturer-id, where the tiebreaker lives); the in-band tiebreaker value semantics + comparison direction (both sides must agree who dials); the channel-open handshake call ordering; the data framing (length prefix size, endianness, max frame); keepalive/liveness numbers. For EACH mismatch: file+line on each side, what differs, and the exact minimal patch for each platform. If they match, say so explicitly per item.\n\n` +
  `Return a list of concrete discrepancies (empty if none), each with per-platform patch instructions.`,
  { label: 'wire-audit', phase: 'WireAudit' }
)

phase('Fix')
const fixes = (await parallel(['android', 'apple'].map(plat => () =>
  agent(
    `Cross-platform wire-compatibility audit found issues across the two implementations. Here is the full audit:\n\n${audit}\n\n` +
    `Apply ONLY the fixes that pertain to the ${plat.toUpperCase()} side, editing files under ${ROOT}/${plat}. Keep both sides converging on the SAME wire format (do not unilaterally change a shared format in a way that breaks the other side, match the spec). Then REBUILD (${plat === 'android' ? 'gradlew assembleDebug with JAVA_HOME openjdk@17' : 'the macOS swiftc build script'}) and confirm it still compiles. If the audit found no ${plat} issues, just confirm the existing build still compiles. Return the build status object.`,
    { label: `fix:${plat}`, phase: 'Fix', schema: BUILD_SCHEMA }
  )
))).filter(Boolean)

return { initialBuilds: builds, wireAudit: audit, finalBuilds: fixes }
