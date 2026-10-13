#!/usr/bin/env python3
"""Capture complete example cards from a running, seeded Manyfold instance."""
import argparse
import math
from pathlib import Path

from playwright.sync_api import sync_playwright


EXAMPLES = [
    ("Avacyn Bust", "Avacyn_Bust.lys", "lychee-avacyn-bust"),
    ("Butterfly drawing", "butterfly_vectorized.lbrn2", "lightburn-project"),
    ("Inventor gear", "gear-preview.ipt", "inventor-part"),
    ("Inventor gear assembly", "gears-preview.iam", "inventor-assembly"),
    ("Curves and shapes", "classic-geometry.lbrn", "lightburn-legacy"),
    ("Fusion saved preview", "fusion-preview.f3d", "fusion-saved-preview"),
]


def dismiss_tour(page):
    close_button = page.locator(".driver-popover-close-btn")
    if close_button.is_visible():
        with page.expect_response(
            lambda response: response.request.method == "PATCH" and response.url.endswith("/users.json")
        ):
            close_button.click()


def match_card_width(page, cards, width):
    """Adjust the browser viewport so genuine grid cards match the README."""
    for _ in range(6):
        bounds = cards.first.bounding_box()
        # Bootstrap's percentage columns can differ by a browser layout unit
        # (1/64px) even at the intended width.
        if abs(bounds["width"] - width) < 0.05:
            return
        columns = sum(
            abs(card.bounding_box()["y"] - bounds["y"]) < 1
            for card in cards.all()
        )
        viewport = page.viewport_size
        adjustment = round((width - bounds["width"]) * columns)
        if adjustment == 0:
            break
        page.set_viewport_size({"width": viewport["width"] + adjustment, "height": viewport["height"]})
    raise RuntimeError(f"Cannot capture Manyfold's cards at {width} CSS pixels without restyling them")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:3216")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--card-width", type=int, default=360, help="Match the README's displayed card width.")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch()
        context = browser.new_context(
            viewport={"width": 1536, "height": 1200},
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
        if cards.count() != len(EXAMPLES):
            raise RuntimeError("Use the seeded example instance containing exactly six model cards")
        match_card_width(page, cards, args.card_width)
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
            bounds = card.bounding_box()
            if abs(bounds["width"] - args.card_width) >= 0.05:
                raise RuntimeError(f"The card for {title!r} does not match the README display width")
            destination = args.output / f"{basename}-card.png"
            # Align the crop to device pixels. Locator screenshots round the
            # fractional grid bounds outwards, producing inconsistent widths
            # that the README would then need to rescale.
            scale = page.evaluate("window.devicePixelRatio")
            scroll = page.evaluate("({x: window.scrollX, y: window.scrollY})")
            top = math.floor((bounds["y"] + scroll["y"]) * scale)
            bottom = math.ceil((bounds["y"] + scroll["y"] + bounds["height"]) * scale)
            clip = {
                "x": round((bounds["x"] + scroll["x"]) * scale) / scale,
                "y": top / scale,
                "width": args.card_width,
                "height": (bottom - top) / scale,
            }
            page.screenshot(path=str(destination), clip=clip, full_page=True,
                animations="disabled", caret="hide")
            print(f"{destination.name}: {args.card_width} x {round(bounds['height'])} CSS pixels")

        context.close()
        browser.close()


if __name__ == "__main__":
    main()
