import {test, expect} from "@playwright/test";

// Every page is exercised beneath the actual Pages repository subpath, with
// external resources and all server writes blocked and recorded as failures.
test.beforeEach(async ({page, baseURL}) => {
  const root = new URL(baseURL);
  const failures = [];
  page.on("pageerror", (error) => failures.push(error.message));
  page.on("console", (message) => { if (message.type() === "error") failures.push(message.text()); });
  page.on("requestfailed", (request) => failures.push(`Failed resource: ${request.url()}`));
  page.on("response", (response) => { if (response.status() >= 400) failures.push(`${response.status()}: ${response.url()}`); });
  await page.route("**/*", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    if (url.origin !== root.origin || !url.pathname.startsWith(root.pathname) || !["GET", "HEAD"].includes(request.method())) {
      failures.push(`Unexpected request: ${request.method()} ${request.url()}`);
      await route.abort();
    } else {
      await route.continue();
    }
  });
  page.demoFailures = failures;
});

test.afterEach(async ({page}) => {
  expect(page.demoFailures, "The static demo must need only its exported files.").toEqual([]);
});

async function ready(page) {
  await expect(page.locator("#main-navbar")).toBeVisible();
  await expect(page.locator("#footer")).toBeVisible();
  await page.evaluate(() => document.fonts.ready);
}

test("the gallery displays ten real Manyfold thumbnail cards", async ({page}) => {
  await page.goto("index.html");
  await ready(page);
  const cards = page.locator(".card.preview-card[data-demo-example]");
  await expect(cards).toHaveCount(10);
  for (const title of ["Avacyn Bust", "Butterfly drawing", "Toy Block", "Hex Nut", "Conveyor box", "Conveyor assembly"]) {
    await expect(cards.filter({hasText: title})).toHaveCount(1);
  }
  const images = cards.locator("img");
  await expect(images).toHaveCount(10);
  await expect.poll(() => images.evaluateAll((nodes) => nodes.every((image) => image.complete && image.naturalWidth === 512))).toBe(true);
  await expect(page.getByText(/pre-rendered thumbnails/i).first()).toBeVisible();
  await page.screenshot({path: "test-results/demo/gallery.png", fullPage: true});
  await page.getByRole("link", {name: "Thumbnail settings", exact: true}).filter({visible: true}).first().click();
  await expect(page).toHaveURL(/settings\.html$/);
  await expect(page.locator("#catwalk-formats")).toBeVisible();
});

test("provider choices and overrides can be explored without a server", async ({page}) => {
  await page.goto("settings.html");
  await ready(page);
  await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  const part = page.locator("#catwalk-enabled-ipt");
  const assembly = page.locator("#catwalk-enabled-iam");
  const stl = page.locator("#catwalk-enabled-stl");
  const fusion = page.locator("#catwalk-enabled-f3d");
  await expect(part).toBeChecked();
  await expect(assembly).toBeChecked();
  await expect(stl).not.toBeChecked();
  await expect(fusion).toBeChecked();
  const stlRow = stl.locator("xpath=ancestor::tr");
  const core = await stlRow.getAttribute("data-demo-core-provider");
  expect(core).toBeTruthy();
  await stl.check();
  await expect(stlRow.locator("[data-demo-provider]")).toHaveText("Catwalk");
  await expect(page.locator("#catwalk-active-overrides")).toContainText(".stl");
  await stl.uncheck();
  await expect(stlRow.locator("[data-demo-provider]")).toHaveText(core);
  await part.uncheck();
  await expect(part.locator("xpath=ancestor::tr").locator("[data-demo-provider]")).toHaveText("Disabled");
  await page.locator("#demo-reset").click();
  await expect(part).toBeChecked();
  await expect(stl).not.toBeChecked();
  await expect(page.locator("#catwalk-active-overrides")).not.toContainText(".stl");
  await page.getByRole("button", {name: "Save thumbnail settings", exact: true}).click();
  await expect(page.locator("#demo-settings-status")).toContainText("not saved here");
  await expect(page).toHaveURL(/settings\.html$/);
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({path: "test-results/demo/settings.png", fullPage: true});
  await page.screenshot({path: "test-results/demo/settings-viewport.png"});
});

test("mobile navigation, gallery and settings remain usable", async ({page}) => {
  await page.setViewportSize({width: 390, height: 844});
  await page.goto("index.html");
  await ready(page);
  await expect(page.locator(".card.preview-card[data-demo-example]")).toHaveCount(10);
  await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.screenshot({path: "test-results/demo/gallery-mobile.png", fullPage: true});
  const navbarToggle = page.locator('#main-navbar [data-bs-toggle="collapse"]').first();
  if (await navbarToggle.isVisible()) {
    await navbarToggle.click();
    await expect(navbarToggle).toHaveAttribute("aria-expanded", "true");
  }
  await page.getByRole("link", {name: "Thumbnail settings", exact: true}).filter({visible: true}).first().click();
  await expect(page.locator("#catwalk-enabled-ipt")).toBeChecked();
  await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.locator("#catwalk-enabled-ipt").uncheck();
  await expect(page.locator("#demo-settings-status")).toContainText("Previewing your choice");
  await page.screenshot({path: "test-results/demo/settings-mobile.png", fullPage: true});
});

test("example PNGs download and backend links remain inactive", async ({page}) => {
  await page.goto("index.html");
  await ready(page);
  const card = page.locator(".card.preview-card[data-demo-example]").filter({hasText: "Conveyor assembly"});
  const download = page.waitForEvent("download");
  await card.getByRole("link", {name: "Download thumbnail", exact: true}).click();
  const result = await download;
  expect(result.suggestedFilename()).toMatch(/inventor-conveyor\.png$/);
  expect(await result.failure()).toBeNull();
  const before = page.url();
  const backend = page.locator("a[data-demo-inert]").filter({visible: true}).first();
  await backend.click();
  expect(page.url()).toBe(before);
});
