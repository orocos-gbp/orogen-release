module Orocos
    def self.validate_toplevel_type(type)
        if type < Typelib::ArrayType
            raise Generation::ConfigError, "array types can be used only in a structure"
        elsif type < Typelib::NumericType && !Typelib::Registry.base_rtt_type?(type)
            raise Generation::ConfigError, "#{type.name} cannot be used as a toplevel type"
        end
    end

    module Generation
        # Module that is used to add code generation functionality to
        # Spec::Property
        module PropertyGeneration
            def used_types; [type] end

            def register_for_generation
                constructor = []
                if default_value
                    constructor << "_#{name}.set(#{cxx_default_value});"
                end
                constructor << "properties()->addProperty( _#{name} );"

                task.add_base_member("property", "_#{name}",
                    "RTT::Property< #{type.cxx_name} >").
                    initializer("_#{name}(\"#{name}\", \"#{doc}\")").
                    constructor(constructor.join("\n"))
            end
        end

        # Module that is used to add code generation functionality to
        # Spec::Attribute
        module AttributeGeneration
            def used_types; [type] end

            def register_for_generation
                constructor = []
                if default_value
                    constructor << "_#{name}.set(#{cxx_default_value});"
                end
                constructor << "attributes()->addAttribute( _#{name} );"

                task.add_base_member("attribute", "_#{name}",
                    "RTT::Attribute< #{type.cxx_name} >").
                    initializer("_#{name}(\"#{name}\")").
                    constructor(constructor.join("\n"))
            end
        end

        # Module that is used to add code generation functionality to Spec::Port
        module PortGeneration
            def used_types
                if type then [type]
                else []
                end
            end

            def register_for_generation
                add =
                    if task.find_event_port(name)
                        "addEventPort"
                    else "addPort"
                    end

                constructor = []
                constructor << "ports()->#{add}(_#{name})"
                if doc
                    constructor << "  .doc(\"#{doc}\")"
                end
                constructor.last << ';'

                kind =
                    case self
                    when InputPort then "input_port_declaration"
                    else "output_port_declaration"
                    end

                task.add_base_member(kind, "_#{name}",
                    "#{orocos_class}< #{type.cxx_name} >").
                    initializer("_#{name}(\"#{name}\")").
                    constructor(constructor.join("\n"))
            end
        end

        # Module that is used to add code generation functionality to
        # Spec::OutputPort
        module OutputPortGeneration
            # Returns the name of the Orocos class for this port (i.e.  one of
            # ReadDataPort, WriteDataPort, DataPort, ReadBufferPort, ...)
	    def orocos_class; "RTT::OutputPort" end

            def register_for_generation
                super

                setup = []
                if keep_last_written_value == :initial
                    setup << "_#{name}.keepLastWrittenValue(false);"
                    setup << "_#{name}.keepNextWrittenValue(true);"
                elsif keep_last_written_value
                    setup << "_#{name}.keepLastWrittenValue(true);"
                    setup << "_#{name}.keepNextWrittenValue(false);"
                else
                    setup << "_#{name}.keepLastWrittenValue(false);"
                    setup << "_#{name}.keepNextWrittenValue(false);"
                end

                task.add_base_construction("output_port", "_#{name}",
                        setup.join("\n"))
            end
        end

        # Module that is used to add code generation functionality to
        # Spec::InputPort
        module InputPortGeneration
            # Returns the name of the Orocos class for this port (i.e.  one of
            # ReadDataPort, WriteDataPort, DataPort, ReadBufferPort, ...)
	    def orocos_class; "RTT::InputPort" end

            def register_for_generation
                super
                if !@do_not_clean
                    task.in_base_hook('start', "_#{name}.clear();")
                end
            end
        end

        # Module that is used to add code generation functionality to
        # Spec::Operation
        module OperationGeneration
            def initialize(task, name)
		@method_name = self.name.dup
		method_name[0, 1] = method_name[0, 1].downcase
            end

            # Returns the set of types that this operation uses, as a
            # ValueSet of Typelib::Type classes.
            def used_types
                [return_type.first].compact + arguments.map { |_, t, _| t }
            end

	    # Returns the argument part of the C++ signature for this callable
	    def argument_signature(with_names = true)
		arglist = arguments.map do |name, type, doc, qualified_type|
                    # Auto-add const-ref for non-trivial types
                    arg =
                        if type.cxx_name == qualified_type && !(type < Typelib::NumericType)
                            "#{type.cxx_name} const &"
                        else
                            qualified_type
                        end

		    if with_names then "#{arg} #{name}"
		    else arg
		    end
		end

		arglist.join(", ")
	    end

            attr_accessor :body

	    # call-seq:
	    #	method_name new_name -> self
            #	method_name -> current_name
	    #
            # Gets or sets the name of the C++ method which is to be called to
            # serve this operation. It default to the method name with the
            # first character set to lowercase (MyMethod becomes myMethod).
	    dsl_attribute(:method_name) { |value| value.to_s }

            # Called to register methods/hook code and so on on the task context
            def register_for_generation
                thread_flag =
                    if in_caller_thread then "RTT::ClientThread"
                    else "RTT::OwnThread"
                    end

                constructor = "provides()->addOperation( _#{name})\n" +
                    "    .doc(\"#{doc}\")"
                if !arguments.empty?
                    constructor += "\n" + arguments.map { |n, _, d| "    .arg(\"#{n}\", \"#{d}\")" }.join("\n")
                end

                if hidden? && !self.body
                    raise InternalError, "a hidden operation must have a body"
                end

                body =
                    if self.body
                        self.body
                    elsif has_return_value?
                        "    return #{return_type.first.cxx_name}();"
                    else ""
                    end

                add = if hidden? then "add_base_method"
                      else "add_user_method"
                      end

                task.add_base_member("operation", "_#{name}", "RTT::Operation< #{signature(false)} >").
                    initializer("_#{name}(\"#{name}\", &#{task.basename}Base::#{method_name}, this, #{thread_flag})").
                    constructor("#{constructor};")

                m = task.send(add, return_type[1], method_name, argument_signature).
                    doc("Handler for the #{method_name} operation").
                    body(body)
            end
        end

        # Module that is used to add code generation functionality to
        # Spec::TaskContext
        #
        # In the generated code, two classes are actually generated:
        # * the auto-generated code is in <tt>.orogen/tasks/[name]Base.cpp</tt>
        #   and <tt>.orogen/tasks/[name]Base.hpp</tt>. These files define the
        #   various attributes related to the task context (i.e. port and
        #   attribute objects) in an <tt>[project.name]::[name]Base</tt> class.
        # * the user-visible code is in <tt>tasks/[name].cpp</tt> and
        #   <tt>tasks/[name].hpp</tt>. These files are the ones that define the
        #   <tt>[project.name]::[name]</tt> class, which is a direct subclass
        #   of the <tt>[project.name]::[name]Base</tt> class.
        #
        # By default, the +Base+ class derives from the
        # <tt>RTT::TaskContext</tt> class.  This can be changed by using the
        # #subclasses method.
        #
        # For all task context objects (ports, properties, ...) there is one
        # attribute, of the right RTT class, added to the generated TaskContext
        # subclass. The attribute name is always the _[object name], so for
        # instance the presence of the following statement
        #   output_port('time', 'double')
        #
        # will cause a <tt>OutputPort<double></tt> attribute named
        # <tt>_time</tt> to be added to the generated class (more specifically,
        # to the +Base+ subclass).
	module TaskContextGeneration
            # The name of the header file containing the C++ code which defines
            # this task context
            def header_file
                if external_definition?
                    library_name, name = self.name.split("::")
                    File.join("#{library_name.downcase}", "#{name}.hpp")
                else
                    File.join("#{project.name.downcase}", "#{basename}.hpp")
                end
            end

            # Returns the name without an eventual library name
            def basename
                library_name, name = self.name.split("::")
                name || library_name
            end

            # True if we are generating for Linux
            def linux?;     project.linux? end
            # True if we are generating for Xenomai
            def xenomai?;   project.xenomai? end

            def class_name
                name
            end

            def initialize(project, name)
                hooks = %w{configure start update error exception fatal stop cleanup}
                @base_hook_code = Hash.new
                hooks.each do |hook_name|
                    @base_hook_code[hook_name] = Array.new
                end

                @generation_handlers = Array.new
                @base_methods = Array.new
                @user_methods = Array.new
                @base_members = Array.new
                @user_members = Array.new
                @base_header_code = Array.new
                @base_implementation_code = Array.new
            end

            # If true, then the initial state of this class cannot be specified.
            # For orogen-declared tasks, it is the same as
            # #needs_configuration?. This mechanism is here for classes that
            # have not been generated by orogen and either have a no way to
            # specify the initial state, or a non-standard one.
            def fixed_initial_state?; @fixed_initial_state || needs_configuration? || (superclass.fixed_initial_state? if superclass) end

            # Declares that the initial state of this class cannot be specified.
            # For orogen-declared tasks, it is the same as
            # #needs_configuration?. This mechanism is here for classes that
            # have not been generated by orogen and either have a no way to
            # specify the initial state, or a non-standard one.
            def fixed_initial_state; @fixed_initial_state = true end

            def check_uniqueness(name)
                super

                # Check if that name is a method name in orocos.rb as well ...
                # To warn about name clashes
                if @orocos_rb.nil?
                    begin
                        require 'orocos'
                        @orocos_rb = true
                    rescue Exception
                        @orocos_rb = false
                    end
                end

                if name.to_str != 'state' && @orocos_rb && !project.kind_of?(ImportedProject)
                    if Orocos::TaskContext.instance_methods.find { |n| n.to_s == name.to_str }
                        STDERR.puts "WARN: #{name} is a method name used in orocos.rb"
                        STDERR.puts "WARN:   if you keep that name, you will not be able to use shortcut access in orocos.rb"
                        STDERR.puts "WARN:   for instance, for a property, you will have to do"
                        STDERR.puts "WARN:      value = my_task.property('#{name}').read(new_value)"
                        STDERR.puts "WARN:   instead of the shorter and clearer"
                        STDERR.puts "WARN:      value = my_task.#{name}"
                    end
                end
            end

            # Returns the type name for the state enumeration
            def state_type_name # :nodoc:
                "#{basename}_STATES"
            end

            # Returns the C++ value name for the given state when defined
            # globally
            def state_global_value_name(state_name, state_type) # :nodoc:
                "#{basename}_#{state_name.upcase}"
            end

            # Returns the C++ value name for the given state when defined in the
            # associated class scope.
            def state_local_value_name(state_name, state_type) # :nodoc:
                state_name.upcase
            end

            # This method is an easier way use boost::shared_ptr in a task
            # context interface. For instance, instead of writing
            #
            #   input_port 'image', '/boost/shared_ptr</Image>'
            #
            # you can write
            #
            #   input_port 'image', shared_ptr('/Image')
            #
            # Additionally, this method makes sure that the corresponding type
            # is actually defined on the project's typekit.
            def shared_ptr(name)
                base_type = project.find_type(name)
                full_name = "/boost/shared_ptr<#{base_type.name}>"
                begin
                    project.find_type(full_name)
                rescue Typelib::NotFound
                    project.typekit { shared_ptr(name) }
                    project.find_type(full_name)
                end
            end

            # This method is an easier way use boost::shared_ptr in a task
            # context interface. For instance, instead of writing
            #
            #   input_port 'image', '/RTT/ReadOnlyPointer</Image>'
            #
            # you can write
            #
            #   input_port 'image', ro_ptr('/Image')
            #
            # Additionally, this method makes sure that the corresponding type
            # is actually defined on the project's typekit.
            def ro_ptr(name)
                base_type =
                    begin
                        project.find_type(name)
                    rescue Typelib::NotFound
                        raise ArgumentError, "type #{name} is not available"
                    end

                full_name = "/RTT/extras/ReadOnlyPointer<#{base_type.name}>"
                begin
                    project.find_type(full_name)
                rescue Typelib::NotFound
                    project.typekit { ro_ptr(name) }
                    project.find_type(full_name)
                end
            end

            # Interface for RTT 1.x methods
            #
            # This raises NotImplementedError with a message asking to convert
            # to RTT2 operations
            def method(name)
                raise NotImplementedError, "RTT 1.x methods must be replaced by RTT 2.x operations. Use #operation"
            end

            # Interface for RTT 1.x commands
            #
            # This raises NotImplementedError with a message asking to convert
            # to RTT2 operations
            def command(name)
                raise NotImplementedError, "RTT 1.x commands must be replaced by RTT 2.x operations. Use #operation"
            end
	    
	    # The set of task libraries that are required by this task context
            #
            # This is the set of task libraries that implement our superclasses
	    def used_task_libraries
		project.used_task_libraries.find_all do |tasklib|
		    tasklib.self_tasks.any? do |task|
			implements?(task.name)
		    end
		end
	    end

            # Returns the set of types that are used to define this task
            # context, as an array of subclasses of Typelib::Type.
            def interface_types
                (all_properties + all_operations + all_ports + all_dynamic_ports).
                    map { |obj| obj.used_types }.
                    flatten.to_value_set.to_a
            end


            # Returns the set of typekits that define the types used in this
            # task's interface. They are required at compile and link time
            # because of the explicit instanciation of interface templates
            # (ports, ...)
            def used_typekits
                types = interface_types
                project.used_typekits.find_all do |tk|
                    types.any? do |type|
                        tk.includes?(type.name)
                    end
                end.to_value_set
            end

            # Validate the constructors of the task files
            # regarding an fixed initial state
            # This might be the case when needs_configuration has been specified
            # on a later stage, but still the constructors need to be changed
            # 
            def validate_constructors(filename, taskname)
                if ! fixed_initial_state?
                    return
                end

                File.open(filename) do |file|
                    begin
                        while true
                            line = file.readline
                            if Regexp.new(taskname + "\(.*\)").match(line)
                                if $1 =~ /TaskCore::TaskState/
                                    puts  "\nWarning: 'needs_configuration' has been specified for the task '#{taskname}', but the task's constructor has not been updated after this change.\n\n Note: setting a TaskState is not allowed in combination with using 'needs_configuration'.\n Constructors in #{filename} and corresponding files require adaption."
                                end
                            end
                        end
                    rescue EOFError
                    end
                end
            end

	    # Generate the code files for this task. This builds to classes:
	    #
	    # * a #{task.name}Base class in .orogen/tasks/#{task.name}Base.{cpp,hpp}
	    #   which is the automatically generated part of the task.
	    # * a #{task.name} class in tasks/#{task.name}.{cpp,hpp} which is
	    #   the user-provided part of the task. This class is a public
	    #   subclass of the Base class.
	    def generate
                return if external_definition?

                if superclass.name == "RTT::TaskContext"
                    hidden_operation("getModelName", "    return \"#{name}\";").
                        returns("std::string").
                        doc("returns the oroGen model name for this task").
                        runs_in_caller_thread

                    add_base_implementation_code("#ifdef HAS_GETTID\n#include <sys/syscall.h>\n#endif")
                    hidden_operation("__orogen_getTID", "    #ifdef HAS_GETTID\nreturn syscall(SYS_gettid);\n#else\nreturn 0;\n#endif").
                        returns("int").
                        doc("returns the PID for this task")
                else
                    add_base_method("std::string", "getModelName", "").
                        body("    return \"#{name}\";")
                end

                new_operations.each(&:register_for_generation)
                self_properties.each(&:register_for_generation)
                self_attributes.each(&:register_for_generation)
                self_ports.each(&:register_for_generation)
                extensions.each do |ext|
                    if ext.respond_to?(:register_for_generation)
                        ext.register_for_generation(self)
                    end
                end

                generation_handlers.each do |h|
                    if h.arity == 1
                        h.call(self)
                    else
                        h.call
                    end
                end

		# Make this task be available in templates as 'task'
		task = self

		base_code_cpp = Generation.render_template 'tasks', 'TaskBase.cpp', binding
		base_code_hpp = Generation.render_template 'tasks', 'TaskBase.hpp', binding
		Generation.save_automatic "tasks", "#{basename}Base.cpp", base_code_cpp
		Generation.save_automatic "tasks", "#{basename}Base.hpp", base_code_hpp

		code_cpp = Generation.render_template "tasks", "Task.cpp", binding
		code_hpp = Generation.render_template "tasks", "Task.hpp", binding
		file_cpp = Generation.save_user "tasks", "#{basename}.cpp", code_cpp
		file_hpp = Generation.save_user "tasks", "#{basename}.hpp", code_hpp

                # Validate constructors of old task files
                validate_constructors(file_cpp, basename)
                validate_constructors(file_hpp, basename)

                fake_install_dir = File.join(project.base_dir, AUTOMATIC_AREA_NAME, project.name)
                FileUtils.mkdir_p fake_install_dir

                FileUtils.ln_sf File.join(project.base_dir, "tasks", "#{basename}.hpp"),
                    File.join(fake_install_dir, "#{basename}.hpp")
                FileUtils.ln_sf File.join(project.base_dir, AUTOMATIC_AREA_NAME, "tasks", "#{basename}Base.hpp"),
                    File.join(fake_install_dir, "#{basename}Base.hpp")

		self
	    end

            # Internal helper that validates +string+, +block+ as a single code
            # object
            #
            # The returned object responds to #call, where #call returns the code string
            # If block is given instead of a string, that block will be called
            # and should return the code as a string
            #
            # If both are given, an ArgumentError exception is raised.
            def self.validate_code_object(string, block)
                if string && block
                    raise ArgumentError, "you can provide either a string or a block, not both"
                end
                if string
                    lambda { string.to_str }
                else
                    block
                end
            end

            # The code snippets that have been declared for the toplevel scope
            # of TaskBase.hpp.
            #
            # It is an array of [include_before, code_snippet] pairs, where
            # +include_before+ is true if the code should be added before the
            # Task class definition and false if it should be added after.
            #
            # See #add_base_header_code
            attr_reader :base_header_code

            # The code snippets that have been declared for the toplevel scope
            # of TaskBase.cpp.
            #
            # It is an array of [include_before, code_snippet] pairs, where
            # +include_before+ is true if the code should be added before the
            # Task class definition and false if it should be added after.
            #
            # See #add_base_implementation_code
            attr_reader :base_implementation_code

            # The set of generation handlers. See #add_generation_handler
            attr_reader :generation_handlers

            # Registers a method that should be called at generation time
            #
            # The provided block will be called at the beginning of the
            # generation process. If the block expects an argument, it will be
            # given the task object
            def add_generation_handler(&block)
                generation_handlers << block
            end

            # Add some code that needs to be added to the toplevel scope in
            # TaskBase.hpp
            def add_base_header_code(string, include_before = true, &block)
                code = TaskContextGeneration.validate_code_object(string, block)
                @base_header_code << [include_before, code]
            end

            # Add some code that needs to be added to the toplevel scope in
            # TaskBase.cpp
            def add_base_implementation_code(string, include_before = true, &block)
                code = TaskContextGeneration.validate_code_object(string, block)
                @base_implementation_code << [include_before, code]
            end

            # Helper method for in_base_hook and in_user_hook
            def in_hook(set, hook, string, &block) # :nodoc:
                code = TaskContextGeneration.validate_code_object(string, block)
                if !set.has_key?(hook)
                    raise ArgumentError, "unknown hook '#{hook}', must be one of #{@additional_base_hook_code.keys.join(", ")}"
                end
                set[hook] << (string || block)
            end

            # Call to add some code to the generated hooks in the Base task
            # classes
            def in_base_hook(hook, string = nil, &block)
                in_hook(@base_hook_code, hook, string, &block)
            end

            attr_reader :base_hook_code

            enumerate_inherited_set "base_method", "base_methods"
            enumerate_inherited_set "user_method", "user_methods"
            attr_reader :base_initializers
            attr_reader :base_constructions

            # Base class for code generation in tasks
            class GeneratedObject
                attr_reader :task

                def self.code_snippet(name, with_generation = true)
                    class_eval <<-EOD
                    def #{name}(code = nil, &block)
                        if !code && !block
                            return @#{name}
                        end
                        code = TaskContextGeneration.validate_code_object(code, block)
                        @#{name} = code
                        self
                    end
                    EOD
                    
                    if with_generation
                        class_eval <<-EOD
                        def generate_#{name}
                            if @#{name}
                                if result = @#{name}.call
                                    result
                                else ""
                                end
                            end
                        end
                        EOD
                    end
                end

                def initialize(task)
                    @task = task
                    @doc = nil
                end

                def doc(*lines)
                    if lines.empty?
                        return @doc
                    end

                    comment = lines.join("\n * ") + "\n"
                    if !@doc
                        @doc = "/* #{comment}"
                    else
                        @doc = " * #{comment}"
                    end
                    self
                end

                def with_indent(number, method)
                    text = send("generate_#{method}")
                    if text
                        indent = " " * number
                        indent + text.split("\n").join("\n#{indent}")
                    end
                end
            end

            # Represents a class member in the generated code
            #
            # This is mainly meant for plugins
            class GeneratedMember < GeneratedObject
                attr_reader :kind
                attr_reader :name
                attr_reader :type

                def initialize(task, kind, name, type = nil)
                    super(task)
                    @kind, @name, @type = kind, name, type
                end

                code_snippet 'initializer'
                code_snippet 'constructor'
                code_snippet 'destructor'

                def generate_declaration
                    if type
                        result = "#{type} #{name};"
                        if doc
                            "#{doc} */#{result}"
                        else result
                        end
                    end
                end
            end

            # Represents a method definition/declaration in the generated code
            #
            # This is mainly meant for plugins
            #
            # See also #in_base_hook to add code to the hooks
            class GeneratedMethod < GeneratedObject
                attr_accessor :in_base

                attr_reader :return_type
                attr_reader :name
                attr_reader :signature
                attr_reader :body

                def initialize(task, return_type, name, signature)
                    super(task)

                    @return_type = return_type
                    @name = name
                    @signature = signature
                end

                code_snippet 'body'

                def generate_declaration
                    decl = "virtual #{return_type} #{name}(#{signature})"
                    if doc
                        decl = "#{doc} */\n#{decl}"
                    end
                    if !body
                        decl = "#{decl} = 0"
                    end
                    "#{decl};"
                end

                def generate_definition
                    if body
                        "#{return_type} #{task.basename}#{'Base' if in_base}::#{name}(#{signature})\n" +
                        "{\n" +
                        generate_body +
                        "\n}"
                    end
                end
            end

            # Helper method for #add_base_method and #add_method
            def add_method(kind, return_type, name, signature)
                self_set = send("self_#{kind}")
                if !name.respond_to?(:to_str)
                    raise ArgumentError, "expected a string for 'name', got #{name} (#{name.class})"
                elsif self_set.any? { |m| m.name == name }
                    raise ArgumentError, "there is already a method called #{name} defined at this level"
                end

                m = GeneratedMethod.new(self, return_type, name, signature)
                self_set << m
                m
            end

            # Define a new method on the Base class of this task
            #
            # +return_type+ is a string representing the C++ return type for
            # this method, +name+ the method name and +signature+ the arguments
            # as they would be written in C++, without the parenthesis.
            #
            # For instance
            #   add_base_method("bool", "isCompleted", "int arg")
            #
            # Generates the method
            #   bool isCompleted(int arg);
            #
            # Note that you do not have to do this explicitely if #add_user_method is
            # called: #add_user_method will add a pure virtual method to the base
            # class
            #
            # It returns an instance of GeneratedMethod that can be used to
            # setup the method further
            def add_base_method(return_type, name, signature = "")
                m = add_method("base_methods", return_type, name, signature)
                m.in_base = true
                m
            end

            # Returns true if +name+ is a method defined with #add_base_method
            # or #add_user_method
            def has_base_method?(name)
                all_base_methods.any? { |m| m.name == name }
            end

            # Define a new method on the user-part class of this task
            #
            # It will also add a pure-virtual method with the same signature on
            # the Base class, to ensure that the user does define the method on
            # its side.
            #
            # It returns an instance of GeneratedMethod that can be used to
            # setup the method further
            def add_user_method(return_type, name, signature = "")
                if !has_base_method?(name)
                    # Add a pure virtual method to remind the user that he
                    # should add it to its implementation
                    add_base_method(return_type, name, signature).
                        doc "If the compiler issues an error at this point, it is probably that",
                            "you forgot to add the corresponding method to the #{self.name} class."
                end
                add_method("user_methods", return_type, name, signature)
            end

            def self_base_members(&block); @base_members end
            def self_user_members(&block); @user_members end

            # Add a code snippet to the generated Base class declaration
            def add_base_member(kind, name, type = nil)
                if @base_members.any? { |m| m.kind == kind && m.name == name }
                    raise ArgumentError, "duplicate name #{kind}:#{name} used for base member"
                end

                m = GeneratedMember.new(self, kind, name, type)
                @base_members << m
                m
            end

            # Add a code snippet to the generated user class declaration
            def add_user_member(kind, name, type = nil)
                if @user_members.any? { |m| m.kind == kind && m.name == name }
                    raise ArgumentError, "duplicate name #{kind}:#{name} used for base member"
                end
                m = GeneratedMember.new(kind, name, type)
                @user_members << m
                m
            end

            def add_base_construction(kind, name, code, &block)
                add_base_member(kind, name).constructor(code, &block)
            end

            def add_base_destruction(kind, name, code)
                add_base_member(kind, name).destructor(code, &block)
            end
	end

        ConfigurationObject = Spec::ConfigurationObject
        Attribute           = Spec::Attribute
        Attribute.include AttributeGeneration
        Property            = Spec::Property
        Property.include PropertyGeneration

        Operation           = Spec::Operation
        Operation.include OperationGeneration

        Port                = Spec::Port
        Port.include PortGeneration
        OutputPort          = Spec::OutputPort
        OutputPort.include OutputPortGeneration
        InputPort           = Spec::InputPort
        InputPort.include InputPortGeneration
        DynamicInputPort    = Spec::DynamicInputPort
        DynamicOutputPort   = Spec::DynamicInputPort

        TaskContext         = Spec::TaskContext
        TaskContext.include TaskContextGeneration
    end
end

