#!/usr/bin/env python3
"""Capture complete example cards from a running, seeded Manyfold instance."""
import argparse
from pathlib import Path

from playwright.sync_api import sync_playwright


EXAMPLES = [
    ("Avacyn Bust", "Avacyn_Bust.lys", "lychee-avacyn-bust"),
    ("Butterfly drawing", "butterfly_vectorized.lbrn2", "lightburn-project"),
    ("Inventor gear", "part-carrier.ipt", "inventor-part"),
    ("Inventor gear assembly", "assembly-carrier.iam", "inventor-assembly"),
    ("Curves and shapes", "classic-geometry.lbrn", "lightburn-legacy"),
    ("Fusion saved preview", "fusion-authored-deflate-preview.f3d", "fusion-saved-preview"),
]


def dismiss_tour(page):
    close_button = page.locator(".driver-popover-close-btn")
    if close_button.is_visible():
        with page.expect_response(
            lambda response: response.request.method == "PATCH" and response.url.endswith("/users.json")
        ):
            close_button.click()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:3216")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parent)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch()
        context = browser.new_context(
            viewport={"width": 1920, "height": 1200},
            device_scale_factor=2,
            color_scheme="light",
            locale="en-GB",
        )
        page = context.new_page()
        # In single-user mode, the first visit signs in automatically and
        # redirects to the dashboard. Keep its session for the model list.
        page.goto(args.base_url, wait_until="networkidle")
        dismiss_tour(page)
        response = page.goto(f"{args.base_url.rstrip('/')}/models", wait_until="networkidle")
        if response is None or response.status != 200:
            raise RuntimeError("Manyfold did not return its model list successfully")
        page.evaluate("document.fonts.ready")
        dismiss_tour(page)

        cards = page.locator(".card.preview-card")
        for title, filename, basename in EXAMPLES:
            card = cards.filter(has=page.get_by_text(title, exact=True))
            if card.count() != 1:
                raise RuntimeError(f"Expected exactly one Manyfold card for {title!r}")
            if filename not in card.inner_text():
                raise RuntimeError(f"The card for {title!r} is missing its filename")
            image = card.locator("img.image-preview")
            if image.count() != 1:
                raise RuntimeError(f"The card for {title!r} is not displaying a render image")
            image.wait_for(state="visible")
            page.wait_for_function(
                "image => image.complete && image.naturalWidth === 512 && image.naturalHeight === 512",
                arg=image.element_handle(),
            )
            if "derivative=render" not in image.get_attribute("src"):
                raise RuntimeError(f"The card for {title!r} is not using Manyfold's render derivative")
            card.scroll_into_view_if_needed()
            destination = args.output / f"{basename}-card.png"
            card.screenshot(path=str(destination), animations="disabled", caret="hide")
            size = card.bounding_box()
            print(f"{destination.name}: {round(size['width'])} x {round(size['height'])} CSS pixels")

        context.close()
        browser.close()


if __name__ == "__main__":
    main()
