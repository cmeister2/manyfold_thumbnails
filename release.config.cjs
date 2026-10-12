module.exports = {
  branches: ["main"],
  repositoryUrl: "https://github.com/cmeister2/manyfold_thumbnails.git",
  tagFormat: "${version}",
  plugins: [
    ["./bin/release-history.mjs", {
      commitAnalyzer: { preset: "conventionalcommits" },
      releaseNotesGenerator: { preset: "conventionalcommits" },
    }],
    ["@semantic-release/exec", {
      prepareCmd: "python3 bin/package ${nextRelease.version}",
    }],
    ["@semantic-release/github", {
      assets: [{ path: "dist/manyfold_thumbnails.zip" }],
      successCommentCondition: false,
      failCommentCondition: false,
      failTitle: false,
      releasedLabels: false,
    }],
  ],
};
