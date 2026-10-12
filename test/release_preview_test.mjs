import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { access, appendFile, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { devNull, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { Writable } from "node:stream";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { previewRelease } from "../bin/release-dry-run.mjs";

const fixtureEnv = {
  PATH: process.env.PATH,
  HOME: process.env.HOME,
  GIT_CONFIG_GLOBAL: devNull,
  GIT_CONFIG_NOSYSTEM: "1",
  GIT_ALLOW_PROTOCOL: "file",
};
const git = (cwd, ...args) => execFileSync("git", [
  "-c", "user.name=Release Preview Test",
  "-c", "user.email=preview@example.invalid",
  "-c", "commit.gpgSign=false",
  "-c", `core.hooksPath=${devNull}`,
  ...args,
], { cwd, env: fixtureEnv, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();

async function fixture(t) {
  const cwd = await mkdtemp(join(tmpdir(), "manyfold-thumbnails-preview-test-"));
  t.after(() => rm(cwd, { recursive: true, force: true }));
  git(cwd, "init", "--quiet", "--initial-branch=main");
  await writeFile(join(cwd, "manyfold_thumbnails.gemspec"), "# Preview fixture plugin\n");
  git(cwd, "add", "manyfold_thumbnails.gemspec");
  await commit(cwd, "feat: initial thumbnail extraction");
  git(cwd, "tag", "0.1.0");
  await writeFile(join(cwd, "scratch.txt"), "Untracked local file\n");
  return cwd;
}

async function commit(cwd, message) {
  await appendFile(join(cwd, "fixture.txt"), `${message}\n`);
  git(cwd, "add", "fixture.txt");
  git(cwd, "commit", "--quiet", "-m", message);
}

async function snapshot(cwd) {
  return {
    head: git(cwd, "rev-parse", "HEAD"),
    branch: git(cwd, "rev-parse", "--abbrev-ref", "HEAD"),
    refs: git(cwd, "for-each-ref", "--format=%(refname) %(objectname)"),
    status: git(cwd, "status", "--porcelain=v1", "--untracked-files=all"),
    source: await readFile(join(cwd, "fixture.txt"), "utf8"),
    scratch: await readFile(join(cwd, "scratch.txt"), "utf8"),
  };
}

async function preview(cwd, extraEnv) {
  let logs = "";
  const output = new Writable({
    write(chunk, _encoding, done) {
      logs += chunk.toString();
      done();
    },
  });
  try {
    const result = await previewRelease({
      cwd, env: { ...fixtureEnv, ...extraEnv }, stdout: output, stderr: output,
    });
    const remote = logs.match(/file:\/\/[^\s]+\/remote\.git/)?.[0];
    assert.ok(remote, "The preview did not report its isolated local remote.");
    await assert.rejects(access(dirname(fileURLToPath(remote))), { code: "ENOENT" });
    return { result, logs };
  } finally {
    output.end();
  }
}

test("detached fork PR previews a feature release without credentials or checkout changes", async (t) => {
  const cwd = await fixture(t);
  await commit(cwd, "feat: add assembly previews");
  git(cwd, "checkout", "--quiet", "--detach");
  await appendFile(join(cwd, "fixture.txt"), "Uncommitted local edit\n");
  const before = await snapshot(cwd);

  const { result, logs } = await preview(cwd, {
    CI: "true",
    GITHUB_ACTIONS: "true",
    GITHUB_EVENT_NAME: "pull_request",
    GITHUB_REF: "refs/pull/42/merge",
    GITHUB_HEAD_REF: "contributor-feature",
    GITHUB_BASE_REF: "main",
    GITHUB_REPOSITORY: "contributor/example-fork",
    GITHUB_SERVER_URL: "https://github.com",
    GITHUB_TOKEN: "invalid-test-token",
    GH_TOKEN: "invalid-test-token",
    GIT_CREDENTIALS: "invalid-test-credentials",
  });

  assert.equal(result.lastRelease.version, "0.1.0");
  assert.equal(result.nextRelease.version, "0.2.0");
  assert.equal(result.nextRelease.gitTag, "0.2.0");
  assert.match(result.nextRelease.notes, /### Features/);
  assert.match(result.nextRelease.notes, /add assembly previews/);
  assert.ok(result.nextRelease.notes.includes(
    "https://github.com/cmeister2/manyfold_thumbnails/compare/0.1.0...0.2.0",
  ));
  assert.match(logs, /Preview complete: 0\.2\.0\. No release was published\./);
  assert.deepEqual(await snapshot(cwd), before);
  assert.equal(git(cwd, "tag", "--list", "0.2.0"), "");
});

test("manual branch previews honor existing tags when no release is needed", async (t) => {
  const cwd = await fixture(t);
  git(cwd, "checkout", "--quiet", "-b", "docs/preview");
  await commit(cwd, "docs: describe installation");
  const before = await snapshot(cwd);

  const { result, logs } = await preview(cwd, {
    CI: "true",
    GITHUB_ACTIONS: "true",
    GITHUB_EVENT_NAME: "workflow_dispatch",
    GITHUB_REF: "refs/heads/docs/preview",
    GITHUB_REPOSITORY: "cmeister2/manyfold_thumbnails",
    GITHUB_TOKEN: "invalid-test-token",
  });

  assert.equal(result, false);
  assert.match(logs, /Preview complete: no release-worthy changes\./);
  assert.deepEqual(await snapshot(cwd), before);
  assert.equal(git(cwd, "tag", "--list"), "0.1.0");
});

test("a zero baseline after inherited plugin history produces the first 0.1.0 thumbnail release", async (t) => {
  const cwd = await mkdtemp(join(tmpdir(), "manyfold-thumbnails-inherited-history-"));
  t.after(() => rm(cwd, { recursive: true, force: true }));
  git(cwd, "init", "--quiet", "--initial-branch=main");
  await commit(cwd, "feat: sync Cults3D models");
  git(cwd, "tag", "template-v0.2.0");
  await commit(cwd, "chore: update the earlier plugin dependencies");
  git(cwd, "tag", "0.0.0");
  const baseline = git(cwd, "rev-parse", "HEAD");
  const inherited = await snapshotForHistory(cwd);

  const beforePlugin = await preview(cwd);
  assert.equal(beforePlugin.result, false);
  assert.deepEqual(await snapshotForHistory(cwd), inherited);

  await writeFile(join(cwd, "manyfold_thumbnails.gemspec"), "# Preview fixture plugin\n");
  git(cwd, "add", "manyfold_thumbnails.gemspec");
  await commit(cwd, "feat: generate Catwalk model thumbnails");
  const before = await snapshotForHistory(cwd);
  const { result } = await preview(cwd);

  assert.equal(result.lastRelease.version, "0.0.0");
  assert.equal(result.lastRelease.gitTag, "0.0.0");
  assert.equal(result.nextRelease.version, "0.1.0");
  assert.equal(result.nextRelease.gitTag, "0.1.0");
  assert.equal(git(cwd, "rev-parse", "0.0.0^{commit}"), baseline);
  assert.equal(result.commits.length, 1);
  assert.match(result.nextRelease.notes, /generate Catwalk model thumbnails/);
  assert.doesNotMatch(result.nextRelease.notes, /Cults3D/);
  assert.deepEqual(await snapshotForHistory(cwd), before);
});

async function snapshotForHistory(cwd) {
  return {
    head: git(cwd, "rev-parse", "HEAD"),
    refs: git(cwd, "for-each-ref", "--format=%(refname) %(objectname)"),
    status: git(cwd, "status", "--porcelain=v1", "--untracked-files=all"),
  };
}
