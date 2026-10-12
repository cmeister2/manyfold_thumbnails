"""Run the plugin's container tests against a disposable release ZIP."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile


PREVIOUS_FILES = {
    "config/initializers/register_hooks.rb": """# frozen_string_literal: true

Rails.application.config.after_initialize do
  PluginManager.register(:navbar, Components::ManyfoldThumbnails::SettingsMenu)
end
""",
    "app/components/manyfold_thumbnails/settings_menu.rb": """# frozen_string_literal: true

module Components::ManyfoldThumbnails
  class SettingsMenu < Components::Base
    include Phlex::Rails::Helpers::LinkTo

    def view_template
      return unless policy(:settings).show?

      link_to view_context.manyfold_thumbnails.root_path,
        class: "nav-link", rel: "nofollow", id: "nav-link-thumbnail-settings" do
        Icon(icon: "image")
        whitespace
        span { t("manyfold_thumbnails.settings.menu") }
      end
    end
  end
end
""",
}


def main():
    root = Path(__file__).resolve().parents[1]
    version = "1.2.3"
    with tempfile.TemporaryDirectory(prefix="manyfold-thumbnails-package-test-") as temporary:
        workspace = Path(temporary)
        source = workspace / "source"
        source.mkdir()
        for directory in ("app", "config", "db", "lib"):
            if (root / directory).exists():
                shutil.copytree(root / directory, source / directory,
                                ignore=shutil.ignore_patterns("vendor"))
        shutil.copy2(root / "manyfold_thumbnails.gemspec", source)
        (source / "bin").mkdir()
        shutil.copy2(root / "bin/package", source / "bin/package")
        subprocess.run([sys.executable, str(source / "bin/package"), version], check=True, stdout=subprocess.DEVNULL)

        plugin = workspace / "plugin"
        # Manyfold installs ZIPs over existing files without removing old ones.
        # Seed the previous navbar integration to verify an in-place upgrade,
        # including the obsolete component left behind after extraction.
        for name, content in PREVIOUS_FILES.items():
            previous_file = plugin / name
            previous_file.parent.mkdir(parents=True, exist_ok=True)
            previous_file.write_text(content)
        with zipfile.ZipFile(source / "dist/manyfold_thumbnails.zip") as archive:
            archive.extractall(plugin)
            for member in archive.infolist():
                if not member.is_dir():
                    (plugin / member.filename).chmod((member.external_attr >> 16) & 0o777)
        (plugin / "test").mkdir()
        print(f"Testing plugin upgrade from release ZIP (version {version}).", flush=True)
        subprocess.run([str(root / "test/run-container"), str(plugin), version], check=True)


if __name__ == "__main__":
    main()
