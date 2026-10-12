import { execFileSync } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import semanticRelease from "semantic-release";
import { analyzeCommits, generateNotes } from "./release-history.mjs";
import config from "../release.config.cjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const manifest = JSON.parse(await readFile(join(root, "package.json"), "utf8"));
const repositoryUrl = manifest.repository.url.replace(/^git\+/, "");
const historyOptions = config.plugins.find(([plugin]) => plugin === "./bin/release-history.mjs")[1];

export async function previewRelease({
  cwd = root, env = process.env, stdout = process.stdout, stderr = process.stderr,
} = {}) {
  // Normal dry runs still verify push access and skip PR/non-release branches.
  // Use a disposable local remote so previews also work without credentials.
  const previewEnv = { ...env };
  for (const name of Object.keys(previewEnv)) {
    if (name.startsWith("GITHUB_") || [
      "CI", "GH_TOKEN", "GIT_CREDENTIALS", "GL_TOKEN", "GITLAB_TOKEN", "BB_TOKEN",
      "BITBUCKET_TOKEN", "BB_TOKEN_BASIC_AUTH", "BITBUCKET_TOKEN_BASIC_AUTH",
    ].includes(name)) delete previewEnv[name];
  }
  const git = (directory, ...args) => execFileSync("git", args, {
    cwd: directory, env: previewEnv, encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
  const head = git(cwd, "rev-parse", "HEAD");
  const temporary = await mkdtemp(join(tmpdir(), "manyfold-thumbnails-release-preview-"));
  const remote = join(temporary, "remote.git");
  const checkout = join(temporary, "checkout");
  const branch = "release-preview";
  try {
    git(temporary, "clone", "--quiet", "--mirror", "--no-hardlinks", resolve(cwd), remote);
    git(remote, "update-ref", `refs/heads/${branch}`, head);
    git(remote, "symbolic-ref", "HEAD", `refs/heads/${branch}`);
    git(temporary, "clone", "--quiet", "--branch", branch, remote, checkout);

    let analyzed = false;
    const result = await semanticRelease({
      ...config,
      branches: [branch],
      repositoryUrl: pathToFileURL(remote).href,
      ci: false,
      dryRun: true,
      plugins: [
        [{ analyzeCommits: async (options, context) => {
          analyzed = true;
          return analyzeCommits(options, context);
        } }, historyOptions],
        [{ generateNotes: (options, context) => generateNotes(options, {
          ...context,
          options: { ...context.options, repositoryUrl },
        }) }, historyOptions],
      ],
    }, { cwd: checkout, env: previewEnv, stdout, stderr });
    if (!analyzed) throw new Error("Release preview skipped commit analysis.");
    stdout.write(result
      ? `Preview complete: ${result.nextRelease.version}. No release was published.\n`
      : "Preview complete: no release-worthy changes.\n");
    return result;
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  await previewRelease();
}
