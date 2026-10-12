import { execFileSync } from "node:child_process";
import { analyzeCommits as analyze } from "@semantic-release/commit-analyzer";
import { generateNotes as notes } from "@semantic-release/release-notes-generator";

// This repository started from a different plugin. Keep its history and tags,
// but only describe commits made after this plugin first appeared in a tree.
function pluginCommits({ cwd, commits }) {
  return commits.filter(({ hash }) => execFileSync("git", [
    "ls-tree", "--name-only", hash, "--",
    "manyfold_thumbnails.gemspec", "manyfold_specialist_previews.gemspec",
  ], { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim());
}

export function analyzeCommits(options, context) {
  return analyze(options.commitAnalyzer, { ...context, commits: pluginCommits(context) });
}

export function generateNotes(options, context) {
  return notes(options.releaseNotesGenerator, { ...context, commits: pluginCommits(context) });
}
