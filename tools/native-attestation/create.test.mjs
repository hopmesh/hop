import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, symlink, unlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { AttestationError, buildStatement, collectSubjects, createBundle } from "./create.mjs";

const sourceSHA = "1".repeat(40);

function canonicalEnvironment() {
  return {
    GITHUB_ACTIONS: "true",
    GITHUB_SERVER_URL: "https://github.com",
    GITHUB_REPOSITORY: "hopmesh/hop",
    GITHUB_REF: "refs/heads/main",
    GITHUB_EVENT_NAME: "push",
    GITHUB_SHA: sourceSHA,
    GITHUB_WORKFLOW_REF: "hopmesh/hop/.github/workflows/native-artifacts.yml@refs/heads/main",
    GITHUB_WORKFLOW_SHA: sourceSHA,
    GITHUB_JOB: "attest",
    GITHUB_RUN_ID: "7",
    GITHUB_RUN_ATTEMPT: "2",
    GITHUB_REPOSITORY_ID: "123",
    GITHUB_REPOSITORY_OWNER_ID: "456",
  };
}

async function fixture() {
  const directory = await mkdtemp(path.join(os.tmpdir(), "hop-native-attestation-"));
  const archive = path.join(directory, "libhop-test.tar.gz");
  const payload = Buffer.from("native archive");
  await writeFile(archive, payload);
  const manifest = path.join(directory, "native-artifacts.json");
  await writeFile(manifest, JSON.stringify({
    artifacts: [{
      filename: path.basename(archive),
      sha256: createHash("sha256").update(payload).digest("hex"),
      size: payload.length,
    }],
  }));
  const signature = path.join(directory, "native-artifacts.json.sig");
  await writeFile(signature, "detached signature");
  return { directory, manifest, signature, archive };
}

test("creates a local provenance bundle for the exact canonical statement", async () => {
  const files = await fixture();
  const output = path.join(files.directory, "native-artifacts.provenance.sigstore.json");
  let statement;
  const fakeSign = async (value) => {
    statement = value;
    return { mediaType: "application/vnd.dev.sigstore.bundle.v0.3+json" };
  };
  const subjects = await createBundle({
    ...files,
    output,
    environment: canonicalEnvironment(),
  }, fakeSign);
  assert.deepEqual(statement.subject, subjects);
  assert.equal(statement._type, "https://in-toto.io/Statement/v1");
  assert.equal(statement.predicateType, "https://slsa.dev/provenance/v1");
  assert.deepEqual(statement.predicate.buildDefinition.resolvedDependencies, [{
    uri: "git+https://github.com/hopmesh/hop@refs/heads/main",
    digest: { gitCommit: sourceSHA },
  }]);
  assert.deepEqual(statement.predicate.runDetails, {
    builder: {
      id: "https://github.com/hopmesh/hop/.github/workflows/native-artifacts.yml@refs/heads/main",
    },
    metadata: {
      invocationId: "https://github.com/hopmesh/hop/actions/runs/7/attempts/2",
    },
  });
  assert.deepEqual(subjects.map((subject) => subject.name), [
    "libhop-test.tar.gz",
    "native-artifacts.json",
    "native-artifacts.json.sig",
  ]);
  assert.deepEqual(JSON.parse(await readFile(output, "utf8")), {
    mediaType: "application/vnd.dev.sigstore.bundle.v0.3+json",
  });
});

test("rejects noncanonical signing contexts", async () => {
  const subjects = [{ name: "artifact", digest: { sha256: "a".repeat(64) } }];
  for (const [name, value] of [
    ["GITHUB_REPOSITORY", "attacker/fork"],
    ["GITHUB_REPOSITORY", "hopmesh/monorepo"],
    ["GITHUB_REF", "refs/heads/feature"],
    ["GITHUB_EVENT_NAME", "workflow_dispatch"],
    ["GITHUB_WORKFLOW_SHA", "2".repeat(40)],
    ["GITHUB_RUN_ATTEMPT", "0"],
  ]) {
    const environment = canonicalEnvironment();
    environment[name] = value;
    assert.throws(() => buildStatement(subjects, environment), AttestationError);
  }
});

test("rejects missing, extra, tampered, and symlinked subjects", async () => {
  const missing = await fixture();
  await unlink(missing.archive);
  await assert.rejects(collectSubjects(missing), /subject is not a regular file/);

  const extra = await fixture();
  await writeFile(path.join(extra.directory, "extra.bin"), "extra");
  await assert.rejects(collectSubjects(extra), /bundle inventory differs/);

  const tampered = await fixture();
  await writeFile(tampered.archive, "tampered archive");
  await assert.rejects(collectSubjects(tampered), /artifact size mismatch|artifact digest mismatch/);

  const linked = await fixture();
  await unlink(linked.archive);
  await symlink(linked.manifest, linked.archive);
  await assert.rejects(collectSubjects(linked), /subject is not a regular file/);
});
