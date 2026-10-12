import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { test } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import releaseConfig from "../release.config.cjs";

const localRequire = createRequire(import.meta.url);
const releaseRequire = createRequire(localRequire.resolve("semantic-release"));
const { generateNotes } = await import(pathToFileURL(
  releaseRequire.resolve("@semantic-release/release-notes-generator"),
).href);
const { analyzeCommits } = await import(pathToFileURL(
  releaseRequire.resolve("@semantic-release/commit-analyzer"),
).href);
const root = fileURLToPath(new URL("../", import.meta.url));
const repositoryUrl = "https://github.com/cmeister2/manyfold_thumbnails";
const historyOptions = releaseConfig.plugins.find(
  (plugin) => Array.isArray(plugin) && plugin[0] === "./bin/release-history.mjs",
)[1];

test("release notes render Conventional Commits templates and links", async () => {
  const notes = await generateNotes(historyOptions.releaseNotesGenerator, {
    cwd: root,
    options: { repositoryUrl },
    lastRelease: { gitTag: "1.0.0" },
    nextRelease: { version: "2.0.0", gitTag: "2.0.0" },
    commits: [
      {
        hash: "1234567890123456789012345678901234567890",
        message: "feat: add assembly previews",
      },
      {
        hash: "abcdef0123456789abcdef0123456789abcdef01",
        message: "fix: repair thumbnail extraction\n\nCloses #42",
      },
      {
        hash: "0123456789abcdef0123456789abcdef01234567",
        message: "feat!: require a supported container\n\nBREAKING CHANGE: Previews require a supported container.",
      },
    ],
  });

  for (const expected of [
    `[2.0.0](${repositoryUrl}/compare/1.0.0...2.0.0)`,
    "### Features",
    "### Bug Fixes",
    "BREAKING CHANGES",
    "Previews require a supported container.",
    "add assembly previews",
    "repair thumbnail extraction",
    `${repositoryUrl}/issues/42`,
    `${repositoryUrl}/commit/1234567890123456789012345678901234567890`,
  ]) {
    assert.ok(notes.includes(expected), `Missing ${JSON.stringify(expected)} in release notes:\n${notes}`);
  }
});

for (const [message, expected] of [
  ["feat: add assembly previews", "minor"],
  ["fix: repair thumbnail extraction", "patch"],
  ["feat!: require a supported container\n\nBREAKING CHANGE: Previews require a supported container.", "major"],
]) {
  test(`commit analysis selects a ${expected} release`, async () => {
    const release = await analyzeCommits(historyOptions.commitAnalyzer, {
      cwd: root,
      commits: [{ hash: "1234567890123456789012345678901234567890", message }],
      logger: { log() {} },
    });
    assert.equal(release, expected);
  });
}
