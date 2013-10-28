module Orocos
    module Spec
        module DynamicPort
            def instanciate(name)
                m = dup
                m.instance_variable_set :@name, name
                m
            end

            def dynamic?; true end

            def pretty_print(pp)
                pp.text "[dyn,#{self.class < InputPort ? "in" : "out"}]#{name}:#{if type then type.name else "any type" end}"
            end
        end

        # Specification for a dynamic output port.
        #
        # Dynamic ports are not statically present, but will be created at
        # runtime. They are added by TaskContext#dynamic_output_port.
        class DynamicOutputPort < OutputPort
            include DynamicPort
        end
        
        # Specification for a dynamic input port.
        #
        # Dynamic ports are not statically present, but will be created at
        # runtime. They are added by TaskContext#dynamic_input_port.
        class DynamicInputPort < InputPort
            include DynamicPort

            def task_trigger # :nodoc:
                @trigger_port = true
            end
        end
    end
end


