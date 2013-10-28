module Orocos
    module Generation
        # Instances of this class represent a typekit that has been imported
        # using Component#using_typekit.
        class ImportedTypekit
            attr_reader :main_project
            attr_reader :name
            attr_reader :pkg
            attr_reader :registry
            attr_reader :typelist
            attr_reader :interface_typelist

            attr_reader :opaques
            attr_reader :opaque_registry

            def self.parse_typelist(typelist_txt)
                raw_typelist = typelist_txt.split("\n").map(&:strip)
                typekit_typelist, typekit_interface_typelist = [], []
                raw_typelist.each do |decl|
                    # using non greedy kleene star to match first expression: .*?
                    # to handle following patterns:
                    # /string
                    # /unsigned char[8]
                    # /unsigned char[8] 0 
                    if decl =~ /^([^\s].*?)(\s+(\d+))?$/
                        type, is_interface = $1, $2
                    end
                    # Validation using a simple exclude pattern
                    if !decl || decl =~ /\s+\d\s+\d/
                        raise InternalError, "Declaration '#{decl}' in a typelist could not be parsed -- wrong type pattern"
                    end

                    typekit_typelist << type
                    if !is_interface || is_interface != '0'
                        typekit_interface_typelist << type
                    end
                end
                return typekit_typelist, typekit_interface_typelist
            end

            def self.from_raw_data(main, name, pkg, registry_xml, typelist_txt)
                typekit_registry = Typelib::Registry.new
                Typelib::Registry.add_standard_cxx_types(typekit_registry)
                typekit_registry.merge_xml(registry_xml)

                typekit_typelist, typekit_interface_typelist = parse_typelist(typelist_txt)
                typekit = self.new(main, name,
                              pkg, typekit_registry,
                              typekit_typelist,
                              typekit_interface_typelist)

                # Now initialize the opaque definitions
                doc = Nokogiri::XML(registry_xml)
                doc.xpath('//opaque').each do |opaque_entry|
                    base_type_name  = opaque_entry['name']
                    inter_type_name = opaque_entry['marshal_as']
                    includes        = opaque_entry['includes']
                    needs_copy      = opaque_entry['needs_copy']
                    spec = OpaqueDefinition.new(
                        typekit_registry.get(base_type_name),
                        inter_type_name,
                        { :includes => includes.split(':'), :needs_copy => (needs_copy == '1') },
                        nil)

                    typekit.opaque_registry.merge(typekit_registry.minimal(base_type_name))
                    typekit.opaques << spec
                end

                typekit
            end

            def export_types(*args); end

            def has_opaques?
                registry.any? { |t| includes?(t) && t.contains_opaques? }
            end

            def interface_type?(typename)
                typename = typename.name if typename.respond_to?(:name)
                interface_typelist.include?(typename)
            end

            def initialize(main_project, name, pkg, registry, typelist, interface_typelist)
                @main_project, @name, @pkg, @registry = main_project, name, pkg, registry
                @typelist = typelist.to_set
                @interface_typelist = interface_typelist.to_set
                @opaques = Array.new
                @opaque_registry = Typelib::Registry.new
            end

            def has_opaques?
                if @has_opaques.nil?
                    @has_opaques = registry.any? { |t| t.opaque? }
                end
                @has_opaques
            end

            # Simply ignore, we load the whole typekit anyway
            def opaque_type(*args); end

            def pkg_name
                pkg.name
            end
            def perform_pending_loads; end
            def pkg_transport_name(transport_name)
                Utilrb::PkgConfig.new(pkg.name.gsub('typekit', "transport-#{transport_name}")).name
            end
            def pkg_corba_name
                pkg_transport_name('corba')
            end
            def include_dirs
                pkg.include_dirs.to_set
            end
            # Returns the full path to the types/ subdir in the include
            # directory
            def types_dir
                File.join(pkg.includedir, name, 'types')
            end

            def self_types
                typelist.map { |name| registry.get(name) }
            end

            def intermediate_type_for(*args)
                main_project.intermediate_type_for(*args)
            end

            def intermediate_type?(*args)
                main_project.intermediate_type?(*args)
            end

            def m_type?(*args)
                main_project.m_type?(*args)
            end


            def using_library(*args); end
            def using_typekit(*args); end

            def includes?(type)
                typename = if type.respond_to?(:name) then type.name
                           else type.to_str
                           end
                typelist.include?(typename)
            end
            def virtual?; false end
        end

        class RTTTypekit < ImportedTypekit
            RTT_INTERFACE_TYPELIST = %w{/bool /double /float /int32_t}
            def initialize(*args)
                super
                @typelist = registry.each.
                    find_all { |t| t < Typelib::NumericType || t < Typelib::NullType }.
                    map(&:name).to_set
                @interface_typelist = RTT_INTERFACE_TYPELIST
            end

            def pkg_name; end
            def pkg_transport_name(transport_name); end
            def include_dirs; Set.new end
            def types_dir; nil end
            def virtual?; true end
        end

        # Instances of this class represent a task library loaded in a
        # component, i.e.  a set of TaskContext defined externally and imported
        # using #using_task_library.
        #
        # For the task contexts imported this way,
        # TaskContext#external_definition?  returns true.
        class ImportedProject < Component
            # The main Component instance that groups all the imported task
            # libraries
            attr_reader :main_project
            # The pkg-config file defining this oroGen project
            attr_reader :pkg
            # The pkg-config file for the task library of this oroGen project
            def tasklib_pkg
                @tasklib_pkg ||= Utilrb::PkgConfig.new("#{name}-tasks-#{Orocos::Generation.orocos_target}")
            end

            def imported?
                true
            end

            # Import in the +base+ component the task library whose orogen
            # specification is included in +file+
            def self.load(main_project, pkg, file, verbose = true)
                new(main_project, pkg).load(file, verbose)
            end

            def initialize(main_project, pkg = nil)
                @main_project = main_project
                @pkg = pkg
                super()

		if pkg && main_project && main_project.has_typekit?(name)
                    using_typekit pkg.project_name
		end
            end

            def include_dirs
                if pkg
                    pkg.include_dirs
                else Set.new
                end
            end

            def load_task_library(name)
                main_project.load_task_library(name)
            end

            def eval(*args, &block)
                result = super
                validate_max_sizes_spec
                result
            end

            def load(*args, &block)
                result = super
                validate_max_sizes_spec
                result
            end

	    def find_interface_type(*args)
                if main_project
                    main_project.find_interface_type(*args)
                else super
                end
	    end

            def find_type(*args)
                if main_project
                    main_project.find_type(*args)
                else super
                end
            end

            def registry
                if main_project
                    main_project.registry
                else super
                end
            end

            def opaque_specification(*args)
                if main_project
                    main_project.opaque_specification(*args)
                else
                    super
                end
            end

            def using_typekit(name)
                if main_project
                    main_project.using_typekit(name)
                else
                    super
                end
            end

            def using_library(*args)
            end

            def using_task_library(name)
                main_project.using_task_library(name)
            end

            def task_context(name, &block) # :nodoc:
                task = super
                task.external_definition = true
                task
            end

            def find_typekit(name)
                main_project.find_typekit(name)
            end

            def find_task_context(name)
                begin
                    super
                rescue ArgumentError
                    if main_project
                        main_project.find_task_context(name)
                    else raise
                    end
                end
            end

	    def find_type(type, is_normalized = false)
		if type
		    if type.respond_to?(:to_str)
                        type = type.gsub('::', '/')
                        if !is_normalized
                            type = Typelib::Type.normalize_typename(type)
                        end
                        begin
                            registry.get(type)
                        rescue Typelib::NotFound
                            typekit(true)
                            registry.get(type)
                        end
		    elsif type.kind_of?(Class) && type <= Typelib::Type
                        type
                    else
			raise ArgumentError, "expected a type object, got #{type}"
		    end
		end
	    end

            # Simply ignore type export directives
            def export_types(*args); self end
            def type_export_policy(*args); self end

	    def used_typekits
		if main_project
		    main_project.used_typekits
		else super
		end
	    end

            def used_task_libraries
                if main_project
                    main_project.used_task_libraries
                else super
                end
            end

	    def interface_type?(name)
		if main_project
		    main_project.interface_type?(name)
		else super
		end
	    end

            def import_types_from(name, *args)
                if main_project && main_project.has_typekit?(name)
                    using_typekit name
                else
                    typekit
                end
            end

            def typekit(create = nil, &block) # :nodoc:
                if @typekit.nil? && @has_typekit.nil?
                    @has_typekit =
                        if main_project && main_project.has_typekit?(name)
                            true
                        elsif !name
                            # This is a workaround about the fucked up reloading
                            # of orogen files. The issue at hand is that
                            # #typekit is called here and there in Project,
                            # while name is not set. if has_typekit was set to
                            # false, the typekit would never be loaded again
                            nil
                        else
                            false
                        end

                    if @has_typekit
                        @typekit = main_project.import_typekit(name)
                        main_project.using_typekit(@typekit)
                    end
                end
                @typekit
            end

            # Task library objects represent an import, and as such they cannot
            # be generated.  This method raises NotImplementedError
            def generate; raise NotImplementedError end
            # Task library objects represent an import, and as such they cannot
            # be generated.  This method raises NotImplementedError
            def generate_build_system; raise NotImplementedError end
        end
    end
end

