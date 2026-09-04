import { createHash } from "node:crypto";
import { lstat, readFile, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { bundleToJSON } from "@sigstore/bundle";
import { CIContextProvider, DSSEBundleBuilder, FulcioSigner, TSAWitness } from "@sigstore/sign";

const MANIFEST_NAME = "native-artifacts.json";
const SIGNATURE_NAME = "native-artifacts.json.sig";
const PROVENANCE_NAME = "native-artifacts.provenance.sigstore.json";
const CANONICAL_REPOSITORY = "https://github.com/hopmesh/hop";
const CANONICAL_GITHUB_REPOSITORY = "hopmesh/hop";
const NATIVE_WORKFLOW = ".github/workflows/native-artifacts.yml";
const MAIN_REF = "refs/heads/main";
const INTOTO_STATEMENT_TYPE = "https://in-toto.io/Statement/v1";
const INTOTO_PAYLOAD_TYPE = "application/vnd.in-toto+json";
const SLSA_PROVENANCE_TYPE = "https://slsa.dev/provenance/v1";
const GITHUB_WORKFLOW_BUILD_TYPE = "https://actions.github.io/buildtypes/workflow/v1";
const GITHUB_FULCIO_URL = "https://fulcio.githubapp.com";
const GITHUB_TSA_URL = "https://timestamp.githubapp.com";
const SIGNING_TIMEOUT_MS = 10_000;
const SIGNING_RETRIES = 3;
const SHA256_RE = /^[0-9a-f]{64}$/;
const SHA_RE = /^[0-9a-f]{40}$/;
const POSITIVE_INTEGER_RE = /^[1-9][0-9]*$/;

export class AttestationError extends Error {}

function requireValue(condition, message) {
  if (!condition) {
    throw new AttestationError(message);
  }
}

async function regularFile(file, directory) {
  const absolute = path.resolve(file);
  requireValue(path.dirname(absolute) === directory, `subject is outside the bundle: ${file}`);
  let metadata;
  try {
    metadata = await lstat(absolute);
  } catch {
    throw new AttestationError(`subject is not a regular file: ${path.basename(file)}`);
  }
  requireValue(metadata.isFile() && !metadata.isSymbolicLink() && metadata.size > 0, `subject is not a regular file: ${path.basename(file)}`);
  return { absolute, metadata };
}

async function digest(file) {
  return createHash("sha256").update(await readFile(file)).digest("hex");
}

export async function collectSubjects({ manifest, signature, directory }) {
  const root = path.resolve(directory);
  requireValue(path.basename(manifest) === MANIFEST_NAME, "manifest filename is not canonical");
  requireValue(path.basename(signature) === SIGNATURE_NAME, "signature filename is not canonical");

  const manifestFile = await regularFile(manifest, root);
  const signatureFile = await regularFile(signature, root);
  let value;
  try {
    value = JSON.parse(await readFile(manifestFile.absolute, "utf8"));
  } catch (error) {
    throw new AttestationError(`manifest cannot be loaded: ${error.message}`);
  }
  requireValue(value && Array.isArray(value.artifacts) && value.artifacts.length > 0, "manifest artifacts are empty");

  const expected = new Set([MANIFEST_NAME, SIGNATURE_NAME]);
  const subjects = [];
  for (const artifact of value.artifacts) {
    requireValue(artifact && typeof artifact.filename === "string", "artifact filename is invalid");
    requireValue(path.basename(artifact.filename) === artifact.filename, `artifact filename is unsafe: ${artifact.filename}`);
    requireValue(!expected.has(artifact.filename), `duplicate artifact filename: ${artifact.filename}`);
    requireValue(Number.isInteger(artifact.size) && artifact.size > 0, `artifact size is invalid: ${artifact.filename}`);
    requireValue(typeof artifact.sha256 === "string" && SHA256_RE.test(artifact.sha256), `artifact digest is invalid: ${artifact.filename}`);
    expected.add(artifact.filename);
    const file = await regularFile(path.join(root, artifact.filename), root);
    requireValue(file.metadata.size === artifact.size, `artifact size mismatch: ${artifact.filename}`);
    requireValue((await digest(file.absolute)) === artifact.sha256, `artifact digest mismatch: ${artifact.filename}`);
    subjects.push({ name: artifact.filename, digest: { sha256: artifact.sha256 } });
  }

  const entries = await readdir(root, { withFileTypes: true });
  const actual = new Set();
  for (const entry of entries) {
    requireValue(entry.isFile() && !entry.isSymbolicLink(), `bundle contains a non-file entry: ${entry.name}`);
    actual.add(entry.name);
  }
  requireValue(actual.size === expected.size && [...actual].every((name) => expected.has(name)), "bundle inventory differs before attestation");

  subjects.push({ name: MANIFEST_NAME, digest: { sha256: await digest(manifestFile.absolute) } });
  subjects.push({ name: SIGNATURE_NAME, digest: { sha256: await digest(signatureFile.absolute) } });
  return subjects.sort((left, right) => left.name.localeCompare(right.name));
}

export function buildStatement(subjects, environment = process.env) {
  const expectedWorkflowRef = `${CANONICAL_GITHUB_REPOSITORY}/${NATIVE_WORKFLOW}@${MAIN_REF}`;
  requireValue(environment.GITHUB_ACTIONS === "true", "signer is not running in GitHub Actions");
  requireValue(environment.GITHUB_SERVER_URL === "https://github.com", "GitHub server is not canonical");
  requireValue(environment.GITHUB_REPOSITORY === CANONICAL_GITHUB_REPOSITORY, "repository is not canonical");
  requireValue(environment.GITHUB_REF === MAIN_REF, "source ref is not canonical main");
  requireValue(environment.GITHUB_EVENT_NAME === "push", "source event is not push");
  requireValue(SHA_RE.test(environment.GITHUB_SHA ?? ""), "source SHA is invalid");
  requireValue(environment.GITHUB_WORKFLOW_REF === expectedWorkflowRef, "workflow ref is not canonical");
  requireValue(environment.GITHUB_WORKFLOW_SHA === environment.GITHUB_SHA, "workflow SHA differs from source SHA");
  requireValue(environment.GITHUB_JOB === "attest", "signer job identity is wrong");
  requireValue(POSITIVE_INTEGER_RE.test(environment.GITHUB_RUN_ID ?? ""), "workflow run ID is invalid");
  requireValue(POSITIVE_INTEGER_RE.test(environment.GITHUB_RUN_ATTEMPT ?? ""), "workflow run attempt is invalid");
  requireValue(POSITIVE_INTEGER_RE.test(environment.GITHUB_REPOSITORY_ID ?? ""), "repository ID is invalid");
  requireValue(POSITIVE_INTEGER_RE.test(environment.GITHUB_REPOSITORY_OWNER_ID ?? ""), "repository owner ID is invalid");

  const identity = `${CANONICAL_REPOSITORY}/${NATIVE_WORKFLOW}@${MAIN_REF}`;
  const invocation = `${CANONICAL_REPOSITORY}/actions/runs/${environment.GITHUB_RUN_ID}/attempts/${environment.GITHUB_RUN_ATTEMPT}`;
  return {
    _type: INTOTO_STATEMENT_TYPE,
    subject: subjects,
    predicateType: SLSA_PROVENANCE_TYPE,
    predicate: {
      buildDefinition: {
        buildType: GITHUB_WORKFLOW_BUILD_TYPE,
        externalParameters: {
          workflow: {
            ref: MAIN_REF,
            repository: CANONICAL_REPOSITORY,
            path: NATIVE_WORKFLOW,
          },
        },
        internalParameters: {
          github: {
            event_name: "push",
            repository_id: environment.GITHUB_REPOSITORY_ID,
            repository_owner_id: environment.GITHUB_REPOSITORY_OWNER_ID,
            runner_environment: "github-hosted",
          },
        },
        resolvedDependencies: [{
          uri: `git+${CANONICAL_REPOSITORY}@${MAIN_REF}`,
          digest: { gitCommit: environment.GITHUB_SHA },
        }],
      },
      runDetails: {
        builder: { id: identity },
        metadata: { invocationId: invocation },
      },
    },
  };
}

async function signStatement(statement) {
  const signer = new FulcioSigner({
    fulcioBaseURL: GITHUB_FULCIO_URL,
    identityProvider: new CIContextProvider("sigstore"),
    timeout: SIGNING_TIMEOUT_MS,
    retry: SIGNING_RETRIES,
  });
  const timestamp = new TSAWitness({
    tsaBaseURL: GITHUB_TSA_URL,
    timeout: SIGNING_TIMEOUT_MS,
    retry: SIGNING_RETRIES,
  });
  const builder = new DSSEBundleBuilder({ signer, witnesses: [timestamp] });
  const bundle = await builder.create({
    data: Buffer.from(JSON.stringify(statement)),
    type: INTOTO_PAYLOAD_TYPE,
  });
  return bundleToJSON(bundle);
}

export async function createBundle(options, sign = signStatement) {
  const output = path.resolve(options.output);
  const root = path.resolve(options.directory);
  requireValue(path.dirname(output) === root && path.basename(output) === PROVENANCE_NAME, "provenance output path is not canonical");
  const subjects = await collectSubjects(options);
  const statement = buildStatement(subjects, options.environment);
  const bundle = await sign(statement);
  requireValue(bundle && typeof bundle === "object", "Sigstore did not return an attestation bundle");
  await writeFile(output, `${JSON.stringify(bundle)}\n`, { flag: "wx", mode: 0o600 });
  return subjects;
}

function argumentsFrom(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    requireValue(flag?.startsWith("--") && value !== undefined, `invalid argument: ${flag ?? ""}`);
    const name = flag.slice(2).replaceAll("-", "_");
    requireValue(["manifest", "signature", "directory", "output"].includes(name) && !(name in options), `unexpected argument: ${flag}`);
    options[name] = value;
  }
  for (const name of ["manifest", "signature", "directory", "output"]) {
    requireValue(options[name], `missing argument: --${name.replaceAll("_", "-")}`);
  }
  return options;
}

async function main() {
  const options = argumentsFrom(process.argv.slice(2));
  await createBundle(options);
  process.stdout.write(`created local Sigstore provenance: ${options.output}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    process.stderr.write(`native attestation rejected: ${error.message}\n`);
    process.exitCode = 1;
  });
}
