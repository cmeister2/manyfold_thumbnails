# frozen_string_literal: true

require_relative "configuration"

module ManyfoldThumbnails
  module Formats
    # Catwalk's model and native-document readers, plus DICOM (which
    # Manyfold categorizes as a model). Keep ordinary image handling in core.
    # .bin is deliberately excluded: Manyfold uses its generic document MIME.
    CATWALK_EXTENSIONS = %w[
      ipt iam
      stl obj ply off pts ptx pcd splat gltf glb 3mf vtk vtp vtu vtr vts vtm
      dae las laz step stp stpnc p21 210 mdl 3ds wrl vrml gml usd usda usdc
      usdz spz vti nrrd nhdr mhd mha dxf bpf qi sbet csd x drc fbx vtkhdf
      e ex2 exo g nc cdf ncdf slpk abc ifc vdb iges igs brep xbf amf lys
      fcstd blend lbrn lbrn2 dwg f3d dcm
    ].freeze
    EXTENSIONS = CATWALK_EXTENSIONS

    def self.extension(record)
      File.extname(record.filename.to_s).delete_prefix(".").downcase
    end

    def self.supported?(record)
      EXTENSIONS.include?(extension(record))
    end

    def self.mime_types
      EXTENSIONS.filter_map { |extension| Mime::Type.lookup_by_extension(extension) }.uniq
    end

    def self.catwalk_mime_types
      CATWALK_EXTENSIONS.filter_map { |extension| Mime::Type.lookup_by_extension(extension) }.uniq
    end

    def self.core_handler_for(type)
      FileHandlers::ALL_HANDLERS
        .reject { |handler| handler.name == "FileHandlers::CatwalkThumbnailer" }
        .select { |handler| handler.const_get(:ENVIRONMENTS).include?(:thumbnail) }
        .select { |handler| handler.can_load?(type) }
        .max_by(&:priority)
    end

    def self.default_enabled_mime_types
      catwalk_mime_types.reject { |type| core_handler_for(type) }.map(&:to_s)
    end

    def self.catwalk_enabled_for_type?(type)
      resolved = case type
      when String then Mime::Type.lookup(type)
      when Symbol then Mime[type]
      else type
      end
      resolved && Configuration.enabled_mime_types.include?(resolved.to_s)
    end

    def self.enabled_extensions
      enabled = Configuration.enabled_mime_types
      CATWALK_EXTENSIONS.select do |extension|
        type = Mime::Type.lookup_by_extension(extension)
        type && enabled.include?(type.to_s)
      end
    end

    def self.catwalk_groups
      enabled = Configuration.enabled_mime_types
      CATWALK_EXTENSIONS.group_by { |extension| Mime::Type.lookup_by_extension(extension) }
        .filter_map do |type, extensions|
          next unless type

          core = core_handler_for(type)
          active = enabled.include?(type.to_s)
          {mime_type: type.to_s, extensions: extensions.sort,
           core_handler: core, enabled: active, overridden: active && !!core}
        end.sort_by { |group| group[:extensions].first }
    end

    def self.handler_label(handler)
      I18n.t("file_handlers.handlers.#{handler.name.demodulize.underscore}",
        default: handler.name.demodulize.titleize)
    end

    def self.thumbnailer_for(record)
      return unless supported?(record)
      return unless catwalk_enabled_for_type?(Mime::Type.lookup_by_extension(extension(record)))

      require_relative "catwalk"
      Catwalk
    end

    def self.register!
      CATWALK_EXTENSIONS.each do |extension|
        next if Mime::Type.lookup_by_extension(extension)

        MediaType.register "model/x-#{extension}", extension.to_sym, category: :model
      end
      # Core memoizes category queries; a boot-time query may precede plugin
      # registration, so invalidate those results before derivative dispatch.
      MediaType.reset_memo_wise
    end
  end
end
