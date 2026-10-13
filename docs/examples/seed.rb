# frozen_string_literal: true

# Run with `bundle exec rails runner /plugins/manyfold_thumbnails/docs/examples/seed.rb`
# inside a disposable Manyfold 0.151.0 container with this plugin loaded.
# The committed PNGs are presentation inputs, not freshly generated thumbnails.
# The Lychee source was not provided: Shrine stores its render derivative without
# a primary attachment. No .lys file or substitute design is created.

require "active_job/queue_adapters/test_adapter"
require "digest"
require "fileutils"
require "json"
require "securerandom"
require "stringio"

abort "Run this seed through rails runner with manyfold_thumbnails loaded." unless
  defined?(Rails.application) && defined?(ManyfoldThumbnails::Engine)

# Model callbacks may queue scanning or federation work. The screenshot seed
# needs only the saved records and render derivatives, so leave jobs unexecuted.
ActiveJob::Base.queue_adapter = :test

examples_root = Pathname.new(ENV.fetch("EXAMPLES_ROOT", "/plugins/manyfold_thumbnails/docs/examples"))
fixtures_root = Pathname.new(ENV.fetch("FIXTURES_ROOT", "/fixtures"))
library_root = Pathname.new("/config/models")

examples = [
  {title: "Avacyn Bust", filename: "Avacyn_Bust.lys", image: "lychee-avacyn-bust.png", sources: []},
  {title: "Butterfly drawing", filename: "butterfly_vectorized.lbrn2", image: "lightburn-project.png",
   sources: ["native_geometry/lightburn/butterfly_vectorized.lbrn2", "formats/native_geometry/lightburn/butterfly_vectorized.lbrn2", "butterfly_vectorized.lbrn2"]},
  {title: "Inventor gear", filename: "part-carrier.ipt", image: "inventor-part.png",
   sources: ["saved-previews/autodesk/part-carrier.ipt", "formats/saved_previews/autodesk/part-carrier.ipt", "part-carrier.ipt"]},
  {title: "Inventor gear assembly", filename: "assembly-carrier.iam", image: "inventor-assembly.png",
   sources: ["saved-previews/autodesk/assembly-carrier.iam", "formats/saved_previews/autodesk/assembly-carrier.iam", "assembly-carrier.iam"]},
  {title: "Curves and shapes", filename: "classic-geometry.lbrn", image: "lightburn-legacy.png",
   sources: ["native_geometry/lightburn/classic-geometry.lbrn", "formats/native_geometry/lightburn/classic-geometry.lbrn", "classic-geometry.lbrn"]},
  {title: "Fusion saved preview", filename: "fusion-authored-deflate-preview.f3d", image: "fusion-saved-preview.png",
   sources: ["formats/saved_previews/fusion-authored-deflate-preview.f3d", "saved_previews/fusion-authored-deflate-preview.f3d", "fusion-authored-deflate-preview.f3d"]}
]

# Validate presentation inputs before creating any database records.
examples.each do |example|
  image = examples_root.join(example.fetch(:image))
  abort "Missing example PNG: #{image}" unless image.file?
  header = image.binread(24)
  abort "Expected a 512 x 512 PNG: #{image}" unless
    header.start_with?("\x89PNG\r\n\x1a\n".b) && header.byteslice(16, 8).unpack("NN") == [512, 512]
end

admin = User.with_role(:administrator).first
unless admin
  admin = User.create!(username: "developer", email: "developer@example.invalid",
    password: SecureRandom.base64(32), approved: true)
  admin.add_role(:administrator)
end
admin.update!(reset_password_token: nil) if admin.first_use?

FileUtils.mkdir_p(library_root)
library = Library.find_or_create_by!(path: library_root.to_s) do |record|
  record.name = "Thumbnail examples"
  record.storage_service = "filesystem"
  record.path_template = "{creator}/{modelName}"
end
library.register_storage
library.make_default if SiteSettings.default_library.nil?

results = examples.map do |example|
  slug = example.fetch(:title).downcase.gsub(/[^a-z0-9]+/, "-")
  model_path = "thumbnail-examples/#{slug}"
  model_directory = library_root.join(model_path)
  FileUtils.mkdir_p(model_directory)
  model = library.models.find_or_initialize_by(path: model_path)
  model.assign_attributes(name: example.fetch(:title), caption: example.fetch(:filename),
    permission_preset: :private)
  model.save!

  source = example.fetch(:sources).map { fixtures_root.join(it) }.find(&:file?)
  file = model.model_files.find_or_initialize_by(filename: example.fetch(:filename))
  if source
    destination = model_directory.join(example.fetch(:filename))
    FileUtils.cp(source, destination)
    file.attachment_attacher.set(ModelFileUploader.uploaded_file(
      storage: library.storage_key,
      id: file.path_within_library,
      metadata: {"filename" => example.fetch(:filename), "size" => destination.size,
                 "mime_type" => Mime::Type.lookup_by_extension(file.extension).to_s}
    ))
    file.size = destination.size
    file.digest = Digest::SHA512.file(destination).hexdigest
  elsif file.persisted? && file.attachment
    # Repeated runs keep source omission truthful even if fixtures disappear.
    file.attachment_attacher.set(nil)
    file.size = nil
    file.digest = nil
  end
  file.save!

  # Shrine treats derivative input paths as disposable and may move or delete
  # them. A memory copy keeps the committed presentation asset untouched.
  image = StringIO.new(examples_root.join(example.fetch(:image)).binread)
  file.attachment_attacher.add_derivatives({render: image}, storage: library.storage_key,
    metadata: {"filename" => example.fetch(:image), "mime_type" => "image/png"})
  file.save!
  model.update!(preview_file: file)

  file.reload
  abort "Render derivative did not survive reload: #{example.fetch(:filename)}" unless
    file.attachment(:render)&.exists? && file.has_render?
  abort "Unexpected primary attachment for display-only example: #{example.fetch(:filename)}" if
    source.nil? && file.attachment

  {title: model.name, caption: model.caption, model_id: model.id, model_public_id: model.public_id,
   file_id: file.id, file_public_id: file.public_id, filename: file.filename,
   image: example.fetch(:image), source_present: !source.nil?,
   source_omission: source.nil? ? (example.fetch(:sources).empty? ? "Source was not provided; render-only display example." : "Fixture was not mounted; render-only display example.") : nil,
   render_id: file.attachment(:render).id}
end

puts JSON.generate(library_id: library.id, user_id: admin.id,
  presentation: "Existing PNGs displayed through Manyfold's normal model cards.", models: results)
