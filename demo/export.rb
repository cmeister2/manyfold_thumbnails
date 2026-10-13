# frozen_string_literal: true
# Demo exporter adapted from Max Dymond's manyfold_openscad (AGPL-3.0-only).
# Original source and copyright: demo/licenses/OPENSCAD-DEMO-NOTICE.txt.

abort "Run bin/build-demo in its disposable container." unless ENV["MANYFOLD_THUMBNAILS_DEMO_BUILD"] == "1"

require "action_dispatch/testing/integration"
require "active_job/queue_adapters/test_adapter"
require "digest"
require "fileutils"
require "json"
require "nokogiri"
require "pathname"
require "securerandom"
require "stringio"
require "uri"
require "warden/test/helpers"
require "yaml"

# Only committed PNGs are imported as render derivatives. No job runs, source
# parser loads, or Catwalk invocation belongs in a static presentation build.
ActiveJob::Base.queue_adapter = :test
Warden.test_mode!

class StaticThumbnailDemoExport
  include Warden::Test::Helpers

  ROOT = Pathname.new("/plugins/manyfold_thumbnails")
  OUTPUT = Pathname.new("/demo-output")
  PUBLIC = Rails.root.join("public")
  REPOSITORY = "https://github.com/cmeister2/manyfold_thumbnails"
  CATWALK_REVISION = "ddfa03730888e933142f47ad56405ac72903854a"
  EXAMPLE_CREDITS = "#{REPOSITORY}/blob/main/docs/examples/README.md"
  NATIVE_CREDITS = "#{REPOSITORY}/blob/main/docs/examples/native/README.md"
  EXAMPLES = [
    {id: "lychee-avacyn-bust", title: "Avacyn Bust", filename: "Avacyn_Bust.lys",
     image: "lychee-avacyn-bust.png", kind: "Existing render", source: EXAMPLE_CREDITS,
     license: EXAMPLE_CREDITS},
    {id: "lightburn-project", title: "Butterfly drawing", filename: "butterfly_vectorized.lbrn2",
     image: "lightburn-project.png", kind: "Native geometry",
     source: "https://github.com/jlucaso1/lbrn2-to-svg/blob/7cea0bf68b7caf4ad8d9b16ea03bd8a90c2c9c49/tests/artifacts/butterfly_vectorized.lbrn2",
     license: "licenses/EXAMPLES-lightburn-MIT.txt"},
    {id: "inventor-part", title: "Inventor gear", filename: "gear-preview.ipt",
     image: "inventor-part.png", kind: "Saved preview", input: "inputs/gear-preview.ipt",
     source: "#{REPOSITORY}/blob/main/docs/examples/inputs/gear-preview.ipt",
     license: "licenses/EXAMPLES-catwalk-MIT.txt"},
    {id: "inventor-assembly", title: "Inventor gear assembly", filename: "gears-preview.iam",
     image: "inventor-assembly.png", kind: "Saved preview", input: "inputs/gears-preview.iam",
     source: "#{REPOSITORY}/blob/main/docs/examples/inputs/gears-preview.iam",
     license: "licenses/EXAMPLES-catwalk-MIT.txt"},
    {id: "lightburn-legacy", title: "Curves and shapes", filename: "classic-geometry.lbrn",
     image: "lightburn-legacy.png", kind: "Native geometry",
     source: "https://github.com/cmeister2/catwalk3d/blob/#{CATWALK_REVISION}/tests/fixtures/native_geometry/lightburn/classic-geometry.lbrn",
     license: "licenses/EXAMPLES-catwalk-MIT.txt"},
    {id: "fusion-saved-preview", title: "Fusion saved preview", filename: "fusion-preview.f3d",
     image: "fusion-saved-preview.png", kind: "Saved preview", input: "inputs/fusion-preview.f3d",
     source: "#{REPOSITORY}/blob/main/docs/examples/inputs/fusion-preview.f3d",
     license: "licenses/EXAMPLES-catwalk-MIT.txt"},
    {id: "fusion-toy-block", title: "Toy Block", filename: "Day#1 - Toy Block v2.f3d",
     image: "native/fusion-toy-block.png", kind: "Native geometry",
     source: "#{NATIVE_CREDITS}#fusion-toy-block", license: "native/FUSION-SAMPLES-README.md"},
    {id: "fusion-hex-nut", title: "Hex Nut", filename: "Day #6 - Hex Nut v2.f3d",
     image: "native/fusion-hex-nut.png", kind: "Native geometry",
     source: "#{NATIVE_CREDITS}#fusion-hex-nut", license: "native/FUSION-SAMPLES-README.md"},
    {id: "inventor-box", title: "Conveyor box", filename: "box.ipt",
     image: "native/inventor-box.png", kind: "Native geometry",
     source: "#{NATIVE_CREDITS}#inventor-box", license: "native/LICENSE-roshbeng.txt"},
    {id: "inventor-conveyor", title: "Conveyor assembly", filename: "conveyor_model.iam",
     image: "native/inventor-conveyor.png", kind: "Native geometry",
     source: "#{NATIVE_CREDITS}#inventor-conveyor", license: "native/LICENSE-roshbeng.txt"}
  ].freeze
  PAGES = {"/models" => "index.html", "/manyfold_thumbnails/" => "settings.html"}.freeze

  def run
    validate_inputs
    seed
    FileUtils.cp(ROOT.join("demo/bootstrap.mjs"), OUTPUT.join("bootstrap.mjs"))
    export_gallery
    export_settings
    export_notices
    export_manifest
    File.write(OUTPUT.join(".nojekyll"), "")
    FileUtils.chmod(0o755, OUTPUT)
    FileUtils.chown_R(Integer(ENV.fetch("DEMO_OWNER_UID")), Integer(ENV.fetch("DEMO_OWNER_GID")), OUTPUT)
    puts "Exported #{EXAMPLES.length} real Manyfold model cards and the thumbnail settings page."
  end

  private

  def validate_inputs
    EXAMPLES.each do |example|
      image = ROOT.join("docs/examples", example.fetch(:image))
      abort "Missing example PNG: #{image}" unless image.file?
      header = image.binread(24)
      abort "Expected a 512 x 512 PNG: #{image}" unless
        header.start_with?("\x89PNG\r\n\x1a\n".b) && header.byteslice(16, 8).unpack("NN") == [512, 512]
      if example[:input]
        input = ROOT.join("docs/examples", example.fetch(:input))
        abort "Missing authored saved-preview input: #{input}" unless input.file?
      end
    end
  end

  def seed
    admin = User.create!(username: "demo", email: "demo@example.invalid",
      password: SecureRandom.hex(24), approved: true)
    admin.add_role(:administrator)
    admin.update!(reset_password_token: nil, tour_state: {"completed" => %w[
      main-navbar nav-link-models nav-link-creators nav-link-collections nav-link-upload nav-link-preferences
    ]})
    library_root = Pathname.new("/config/models")
    FileUtils.mkdir_p(library_root)
    library = Library.create!(name: "Thumbnail examples", path: library_root.to_s,
      storage_service: "filesystem", path_template: "{creator}/{modelName}")
    library.register_storage
    library.make_default
    SiteSettings.generate_model_renders = true
    ManyfoldThumbnails::Configuration.reset!

    @examples = EXAMPLES.map do |example|
      model = library.models.create!(name: example.fetch(:title), caption: example.fetch(:filename),
        path: "thumbnail-examples/#{example.fetch(:id)}", permission_preset: :private)
      directory = library_root.join(model.path)
      FileUtils.mkdir_p(directory)
      file = model.model_files.new(filename: example.fetch(:filename))
      if example[:input]
        destination = directory.join(example.fetch(:filename))
        FileUtils.cp(ROOT.join("docs/examples", example.fetch(:input)), destination)
        file.attachment_attacher.set(ModelFileUploader.uploaded_file(
          storage: library.storage_key, id: file.path_within_library,
          metadata: {"filename" => file.filename, "size" => destination.size,
                     "mime_type" => Mime::Type.lookup_by_extension(file.extension).to_s}
        ))
        file.size = destination.size
        file.digest = Digest::SHA512.file(destination).hexdigest
      end
      file.save!
      # Shrine may consume derivative inputs. A memory copy preserves the
      # committed PNG, including for records with no primary source attachment.
      png = ROOT.join("docs/examples", example.fetch(:image)).binread
      file.attachment_attacher.add_derivatives({render: StringIO.new(png)}, storage: library.storage_key,
        metadata: {"filename" => File.basename(example.fetch(:image)), "mime_type" => "image/png"})
      file.save!
      model.update!(preview_file: file)
      file.reload
      abort "Render derivative changed for #{file.filename}" unless file.has_render? && file.attachment(:render).read == png
      abort "Invented primary source for #{file.filename}" if example[:input].nil? && file.attachment
      output = "thumbnails/#{example.fetch(:id)}.png"
      FileUtils.mkdir_p(OUTPUT.join("thumbnails"))
      File.binwrite(OUTPUT.join(output), png)
      route = Rails.application.routes.url_helpers.model_model_file_path(model, file,
        format: file.extension, derivative: "render")
      example.merge(model: model, file: file, render_url: route, output: output)
    end
    @render_urls = @examples.to_h { |example| [example.fetch(:render_url), example] }
    @session = ActionDispatch::Integration::Session.new(Rails.application)
    @session.host!(PublicUrl.hostname)
    @session.https! if Rails.application.config.assume_ssl
    login_as(admin, scope: :user)
  end

  def request(path)
    @session.get(path)
    abort "Demo export request #{path} returned #{@session.response.status} (#{@session.response.headers['Location']}): #{@session.response.body[0, 500]}" unless @session.response.status == 200
    @session.response.body
  end

  def export_gallery
    document = Nokogiri::HTML(request("/models"))
    cards = document.css(".card.preview-card")
    abort "Expected #{EXAMPLES.length} genuine Manyfold cards; found #{cards.length}" unless cards.length == EXAMPLES.length
    seen = []
    cards.each do |card|
      image = card.at_css("img.image-preview") or abort "Missing Manyfold render image"
      example = @render_urls[request_uri(image["src"])] or abort "Unknown Manyfold render route: #{image['src']}"
      seen << example.fetch(:id)
      card["data-demo-example"] = example.fetch(:id)
      card["data-demo-source-kind"] = example.fetch(:kind).downcase.tr(" ", "-")
      card["data-demo-filename"] = example.fetch(:filename)
      image["data-demo-thumbnail"] = example.fetch(:id)
      image["alt"] = "#{example.fetch(:title)} · #{example.fetch(:kind)}"
      body = card.at_css(".card-body") or abort "Missing Manyfold card body"
      badge = Nokogiri::XML::Node.new("p", document)
      badge["class"] = "small mt-2 mb-1"
      badge["data-demo-caption"] = "true"
      badge.content = example.fetch(:kind)
      body.add_child(badge)
      credits = Nokogiri::XML::Node.new("p", document)
      credits["class"] = "small mb-0 d-flex flex-wrap gap-2"
      add_link(credits, "Source and credits", example.fetch(:source), "data-demo-source" => "true")
      add_link(credits, "License information", example.fetch(:license), "data-demo-license" => "true")
      add_link(credits, "Download thumbnail", example.fetch(:output), "download" => "", "data-demo-download" => "true")
      body.add_child(credits)
    end
    abort "Gallery duplicated or omitted an example" unless seen.sort == EXAMPLES.map { |example| example.fetch(:id) }.sort
    finish_page(document, "index.html", "Thumbnail gallery · Manyfold thumbnails demo")
  end

  def export_settings
    document = Nokogiri::HTML(request("/manyfold_thumbnails/"))
    content = document.at_css(".row.flex-nowrap > .col#content") or abort "Missing real settings content column"
    content.parent["id"] = "demo-settings-layout"
    # The host uses #content for both its outer main and inner settings column.
    # Its global flex:1 0 auto makes that column as wide as the viewport, then
    # adds the sidebar. Scope the static demo's responsive adjustment to this
    # wrapper so the real sidebar, form and table can fit their available space.
    style = Nokogiri::XML::Node.new("style", document)
    style.content = <<~CSS
      #demo-settings-layout > .col#content { flex: 1 1 0%; min-width: 0; }
      @media (max-width: 767.98px) {
        #demo-settings-layout { flex-wrap: wrap !important; }
        #demo-settings-layout > .col#content { flex-basis: 100%; }
      }
    CSS
    document.at_css("head").add_child(style)
    form = document.at_css("form:has(#catwalk-formats)") or abort "Missing real thumbnail settings form"
    form["data-demo-settings"] = "true"
    form["data-demo-catwalk-provider"] = I18n.t("file_handlers.handlers.catwalk_thumbnailer")
    form["data-demo-disabled-provider"] = I18n.t("manyfold_thumbnails.settings.show.disabled")
    overrides = document.at_css("#catwalk-active-overrides") or abort "Missing real active overrides label"
    overrides["data-demo-overrides-empty"] = I18n.t("manyfold_thumbnails.settings.show.overrides.none")
    overrides["data-demo-overrides-active"] = I18n.t("manyfold_thumbnails.settings.show.overrides.active")
    groups = ManyfoldThumbnails::Formats.catwalk_groups.to_h { |group| [group.fetch(:mime_type), group] }
    rows = document.css("#catwalk-formats tbody tr")
    abort "Incomplete real format table" unless rows.length == groups.length
    rows.each do |row|
      group = groups.fetch(row["data-mime-type"])
      row["data-demo-core-provider"] = group[:core_handler] ? ManyfoldThumbnails::Formats.handler_label(group[:core_handler]) : ""
      row["data-demo-extensions"] = group.fetch(:extensions).map { |extension| ".#{extension}" }.join(", ")
      row["data-demo-default"] = group.fetch(:enabled).to_s
      checkbox = row.at_css('input[type="checkbox"]') or abort "Missing real format checkbox"
      checkbox["data-demo-default"] = group.fetch(:enabled).to_s
      provider = row.css("td").last or abort "Missing real current provider cell"
      provider["data-demo-provider"] = "true"
    end
    save = form.at_css('input[type="submit"], button[type="submit"]') or abort "Missing real Save thumbnail settings button"
    save["data-demo-inert"] = "true"
    save["data-demo-save"] = "true"
    reset = Nokogiri::XML::Node.new("button", document)
    reset["type"] = "button"
    reset["id"] = "demo-reset"
    reset["class"] = "btn btn-outline-secondary mt-2"
    reset.content = "Reset demo choices"
    form.add_next_sibling(reset)
    finish_page(document, "settings.html", "Thumbnail settings · Manyfold thumbnails demo")
  end

  def finish_page(document, page, title)
    abort "Missing real Manyfold application layout" unless document.at_css("#main-navbar") && document.at_css("#footer") && document.at_css("#content")
    # The exported host HTML and styling stay intact. Its application runtime
    # needs Rails, so the demo supplies only local navigation and form behavior.
    document.css("script").remove
    document.css('link[rel="modulepreload"], link[rel="preload"][as="script"], meta[name="csrf-token"], meta[name="csrf-param"], meta[name="csp-nonce"], input[name="authenticity_token"], turbo-cable-stream-source').remove
    document.css("[nonce]").each { |node| node.remove_attribute("nonce") }
    # Rebased CSS has different bytes and cannot retain the original Vite SRI.
    document.css('link[rel="stylesheet"][integrity]').each { |node| node.remove_attribute("integrity") }
    document.css("a[href]").each do |link|
      next unless backend_url?(link["href"])
      target = PAGES[request_uri(link["href"])]
      if target
        link["href"] = target
        link["data-demo-navigation"] = "true"
        link.remove_attribute("data-turbo-method")
      else
        link["href"] = "#"
        link["data-demo-inert"] = "true"
      end
    end
    document.css("form").each do |form|
      form.remove_attribute("action")
      form.remove_attribute("method")
      form["data-demo-inert"] = "true" unless form.key?("data-demo-settings")
    end
    document.css("link[href], img[src]").each do |node|
      attribute = node.name == "img" ? "src" : "href"
      url = node[attribute]
      next unless url&.start_with?("/")
      example = @render_urls[request_uri(url)]
      node[attribute] = example ? example.fetch(:output) : copy_asset(url)
    end
    document.css("[style]").each do |node|
      node["style"] = rewrite_css_urls(node["style"], base_url: PAGES.key(page))
    end
    document.at_css("title").content = title
    catwalk_version = JSON.parse(ROOT.join("config/catwalk.json").read).fetch("version")
    native_note = if Gem::Version.new(catwalk_version) < Gem::Version.new("2.1.0")
      "The native CAD examples use Catwalk's new native readers. The plugin's configured Catwalk #{catwalk_version} release uses saved previews for Inventor and Fusion."
    else
      "Catwalk #{catwalk_version} can render supported native Inventor and Fusion geometry when a saved preview is unavailable."
    end
    document.at_css("#content").prepend_child(Nokogiri::HTML.fragment(<<~HTML))
      <aside class="alert alert-info mt-3" aria-label="Thumbnail demo">
        <strong>Manyfold thumbnails demo.</strong> These are pre-rendered thumbnails displayed in Manyfold's real model cards.
        Settings choices work locally; saving, uploads and other server actions are inactive.
        <p class="small mt-2 mb-0">#{ERB::Util.html_escape(native_note)}</p>
        <nav class="d-flex flex-wrap gap-3 mt-2" aria-label="Demo pages">
          <a href="index.html">Thumbnail gallery</a>
          <a href="settings.html">Thumbnail settings</a>
          <a href="#{REPOSITORY}">Plugin repository</a>
          <a href="notices.html">Sources and licenses</a>
        </nav>
        <p id="demo-settings-status" role="status" aria-live="polite" class="small mt-2 mb-0">This static demo does not render files or save settings.</p>
      </aside>
    HTML
    script = Nokogiri::XML::Node.new("script", document)
    script["type"] = "module"
    script["src"] = "bootstrap.mjs"
    document.at_css("head").add_child(script)
    File.write(OUTPUT.join(page), document.to_html)
  end

  def add_link(parent, text, href, attributes = {})
    link = Nokogiri::XML::Node.new("a", parent.document)
    link["href"] = href
    attributes.each { |key, value| link[key] = value }
    link.content = text
    parent.add_child(link)
  end

  def request_uri(url)
    uri = URI.parse(url)
    uri.path.to_s + (uri.query ? "?#{uri.query}" : "")
  end

  def backend_url?(url)
    return false if url.start_with?("#", "mailto:")
    # Demo links already point at exported assets; all other relative host
    # routes require a backend. The exporter never creates a source download.
    return false if url == "index.html" || url == "settings.html" || url == "notices.html" || url.start_with?("thumbnails/", "licenses/", "native/")
    uri = URI.parse(url)
    uri.relative? || uri.host == PublicUrl.hostname
  end

  # Copy the exact pinned host assets. Rebase local CSS dependencies so they
  # remain local beneath a GitHub Pages repository path; never copy host JS.
  def copy_asset(url)
    uri = URI.parse(url)
    source = PUBLIC.join(uri.path.delete_prefix("/")).cleanpath
    unless source.file?
      manifest = JSON.parse(PUBLIC.join("vite/.vite/manifest-assets.json").read)
      entries = manifest.values.select { |entry| File.basename(entry.fetch("src")) == File.basename(uri.path) }
      if entries.one?
        uri.path = "/vite/#{entries.first.fetch('file')}"
        source = PUBLIC.join(uri.path.delete_prefix("/")).cleanpath
      end
    end
    abort "Unsafe host asset path #{url}" unless source.to_s.start_with?("#{PUBLIC}/") && source.file?
    abort "Host scripts are not part of this demo: #{url}" if %w[.js .mjs .wasm].include?(source.extname)
    relative = Pathname.new("host").join(source.relative_path_from(PUBLIC))
    destination = OUTPUT.join(relative)
    return relative.to_s if destination.file?
    FileUtils.mkdir_p(destination.dirname)
    if source.extname == ".css"
      destination.write(rewrite_css_urls(source.read, base_url: uri.path, relative_to: relative.dirname))
    else
      FileUtils.cp(source, destination)
    end
    relative.to_s
  end

  # Both host stylesheets and inline card backgrounds must resolve to exported
  # assets. Fragment-only references and data URLs remain within their document.
  def rewrite_css_urls(css, base_url:, relative_to: Pathname.new("."))
    rewritten = css.gsub(/url\(\s*(['"]?)(?!data:)([^'"\s\)]+)\1\s*\)/) do |original|
      dependency = Regexp.last_match(2)
      next original if dependency.start_with?("#")
      abort "External runtime CSS asset #{dependency}" if dependency.start_with?("http:", "https:", "//")
      path = dependency.start_with?("/") ? dependency : URI.join("http://localhost#{base_url}", dependency).request_uri
      example = @render_urls[request_uri(path)]
      copied = Pathname.new(example ? example.fetch(:output) : copy_asset(path))
      "url(#{copied.relative_path_from(relative_to)})"
    end
    abort "External runtime CSS import" if rewritten.match?(/@import\s+(?:url\()?['"]?(?:https?:|\/\/)/)
    rewritten
  end

  def export_notices
    licenses = OUTPUT.join("licenses")
    FileUtils.mkdir_p(licenses)
    FileUtils.cp_r(ROOT.join("demo/licenses/.").to_s, licenses)
    FileUtils.cp(Rails.root.join("LICENSE.md"), licenses.join("MANYFOLD-AGPL-3.0.txt"))
    FileUtils.cp(ROOT.join("docs/examples/LICENSE-catwalk.txt"), licenses.join("EXAMPLES-catwalk-MIT.txt"))
    FileUtils.cp(ROOT.join("docs/examples/LICENSE-lightburn-project.txt"), licenses.join("EXAMPLES-lightburn-MIT.txt"))
    native = OUTPUT.join("native")
    FileUtils.mkdir_p(native)
    ROOT.join("docs/examples/native").glob("*").select { |path| path.file? && %w[.md .txt].include?(path.extname) }.each do |path|
      FileUtils.cp(path, native.join(path.basename))
    end
    verify_host_dependency_versions
    host_revision = Rails.application.config.git_sha
    File.write(OUTPUT.join("notices.html"), <<~HTML)
      <!DOCTYPE html>
      <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Thumbnail demo sources and licenses</title></head>
      <body><main>
        <h1>Thumbnail demo sources and licenses</h1>
        <p><a href="index.html">Thumbnail gallery</a> · <a href="settings.html">Thumbnail settings</a></p>
        <p>This static site exports the real Manyfold model cards, application layout and plugin settings template. All thumbnails are committed PNG presentation inputs; the site does not parse designs, generate images or save settings.</p>
        <ul>
          <li><a href="#{REPOSITORY}">Plugin and demo source</a></li>
          <li>Adapted demo build, export and navigation code: <a href="https://github.com/cmeister2/manyfold_openscad/tree/41a967e1d76fd10924cce1f2605e0422c81bcf5e/demo">original OpenSCAD demo source</a> · <a href="licenses/OPENSCAD-DEMO-NOTICE.txt">Max Dymond's copyright and source notice</a> · <a href="licenses/OPENSCAD-DEMO-AGPL-3.0.txt">AGPL-3.0-only license for the adapted demo code</a></li>
          <li><a href="https://github.com/manyfold3d/manyfold/tree/#{host_revision}">Manyfold 0.151.0 source</a> · <a href="licenses/MANYFOLD-AGPL-3.0.txt">Manyfold license</a></li>
          <li><a href="licenses/README.md">Host stylesheet and icon font notices</a> · <a href="licenses/manifest.json">Pinned image and exact dependency sources</a></li>
          <li><a href="#{EXAMPLE_CREDITS}">Original thumbnail sources and credits</a> · <a href="licenses/EXAMPLES-catwalk-MIT.txt">Catwalk example MIT license</a> · <a href="licenses/EXAMPLES-lightburn-MIT.txt">Butterfly example MIT license</a></li>
          <li><a href="#{NATIVE_CREDITS}">Native CAD thumbnail producer inputs, source and retained licenses</a></li>
          <li><a href="native/README.md">Retained native example source notes</a> · <a href="native/FUSION-SAMPLES-README.md">Fusion sample licensing declaration</a> · <a href="native/LICENSE-roshbeng.txt">Inventor example MIT license</a></li>
          <li><a href="examples.json">Presentation manifest and image checksums</a></li>
        </ul>
        <p>Avacyn Bust is a maintainer-provided thumbnail from an existing Manyfold library. Its original Lychee design was not supplied and is not redistributed. Autodesk saved-preview inputs are authored image containers; the separate native CAD examples render genuine producer geometry.</p>
        <p>The gallery's original Manyfold actions are inactive. Thumbnail PNG downloads are available without distributing source CAD files.</p>
      </main></body></html>
    HTML
  end

  def verify_host_dependency_versions
    notices = JSON.parse(ROOT.join("demo/licenses/manifest.json").read)
    abort "Demo notices do not match the host revision" unless notices.fetch("manyfold").fetch("source").end_with?("/#{Rails.application.config.git_sha}")
    lock = YAML.safe_load(Rails.root.join("yarn.lock").read)
    notices.fetch("packages").each do |package|
      entries = lock.select { |key, _value| key.start_with?("#{package.fetch('package')}@") }
      versions = entries.values.map { |entry| entry.fetch("version") }.uniq
      abort "Demo notice version does not match pinned #{package.fetch('package')}: #{versions.inspect}" unless versions == [package.fetch("version")]
    end
  end

  def export_manifest
    manifest = {
      presentation: "Committed PNGs displayed through real Manyfold model cards; no runtime rendering.",
      manyfold_version: "0.151.0",
      manyfold_source: "https://github.com/manyfold3d/manyfold/tree/#{Rails.application.config.git_sha}",
      pages: ["index.html", "settings.html", "notices.html"],
      examples: @examples.map do |example|
        {id: example.fetch(:id), title: example.fetch(:title), filename: example.fetch(:filename),
         thumbnail: example.fetch(:output), kind: example.fetch(:kind), width: 512, height: 512,
         sha256: Digest::SHA256.file(OUTPUT.join(example.fetch(:output))).hexdigest,
         source_url: example.fetch(:source), license_url: example.fetch(:license),
         primary_source_present: !!example[:input],
         source_omission: example[:input] ? nil : "Render-only display example; no primary CAD source is attached or published."}
      end
    }
    File.write(OUTPUT.join("examples.json"), JSON.pretty_generate(manifest) + "\n")
  end
end

StaticThumbnailDemoExport.new.run
