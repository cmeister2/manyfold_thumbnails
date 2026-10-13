import {defineConfig} from "@playwright/test";

const port = process.env.THUMBNAILS_DEMO_PORT || "4174";

export default defineConfig({
  testDir: "./test/demo",
  outputDir: "test-results/demo",
  timeout: 60000,
  expect: {timeout: 10000},
  workers: 1,
  use: {
    browserName: "chromium",
    headless: true,
    baseURL: `http://127.0.0.1:${port}/manyfold_thumbnails/`,
    viewport: {width: 1440, height: 1000},
    trace: "retain-on-failure",
  },
  webServer: {
    command: "node test/demo/serve.mjs dist/demo",
    url: `http://127.0.0.1:${port}/manyfold_thumbnails/`,
    reuseExistingServer: false,
    timeout: 15000,
  },
  reporter: "list",
});
