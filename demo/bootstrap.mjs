// Adapted from the OpenSCAD demo; attribution and license are in demo/licenses.
// The exported pages keep Manyfold's markup without connecting to its server.
document.addEventListener("submit", (event) => {
  event.preventDefault();
  event.stopImmediatePropagation();
  if (event.target.matches("[data-demo-settings]")) {
    document.querySelector("#demo-settings-status").textContent =
      "This is a static demo. Thumbnail settings are not saved here.";
  }
}, {capture: true});

document.addEventListener("click", (event) => {
  if (event.target.closest("a[data-demo-inert], button[data-demo-inert]")) {
    event.preventDefault();
    event.stopImmediatePropagation();
    return;
  }
  const toggle = event.target.closest("[data-bs-toggle]");
  if (!toggle) return;
  if (toggle.dataset.bsToggle === "collapse") {
    const target = document.querySelector(toggle.dataset.bsTarget || toggle.getAttribute("href"));
    if (target) {
      event.preventDefault();
      toggle.setAttribute("aria-expanded", String(target.classList.toggle("show")));
    }
  } else if (toggle.dataset.bsToggle === "dropdown") {
    const menu = toggle.parentElement.querySelector(".dropdown-menu");
    if (menu) {
      event.preventDefault();
      toggle.setAttribute("aria-expanded", String(menu.classList.toggle("show")));
    }
  }
});

document.addEventListener("keydown", (event) => {
  if (event.key !== "Escape") return;
  document.querySelectorAll(".dropdown-menu.show").forEach((menu) => {
    menu.classList.remove("show");
    menu.parentElement.querySelector('[data-bs-toggle="dropdown"]')?.setAttribute("aria-expanded", "false");
  });
});

const settings = document.querySelector("[data-demo-settings]");
if (settings) {
  const rows = [...settings.querySelectorAll("tr[data-mime-type]")];
  const status = document.querySelector("#demo-settings-status");
  const overridesLabel = document.querySelector("#catwalk-active-overrides");
  const updateProviders = () => {
    const overrides = [];
    for (const row of rows) {
      const enabled = row.querySelector('input[type="checkbox"]').checked;
      const core = row.dataset.demoCoreProvider;
      row.querySelector("[data-demo-provider]").textContent = enabled
        ? settings.dataset.demoCatwalkProvider
        : core || settings.dataset.demoDisabledProvider;
      if (enabled && core) overrides.push(row.dataset.demoExtensions);
    }
    overridesLabel.textContent = overrides.length
      ? `${overridesLabel.dataset.demoOverridesActive} ${overrides.join(", ")}`
      : overridesLabel.dataset.demoOverridesEmpty;
  };
  settings.addEventListener("change", (event) => {
    if (!event.target.matches('input[type="checkbox"]')) return;
    updateProviders();
    status.textContent = "Previewing your choice in this demo. Save applies settings only in Manyfold.";
  });
  document.querySelector("#demo-reset").addEventListener("click", () => {
    for (const row of rows) {
      const checkbox = row.querySelector('input[type="checkbox"]');
      checkbox.checked = checkbox.defaultChecked;
    }
    updateProviders();
    status.textContent = "Default provider choices restored in this demo.";
  });
}
