require 'ruote'
require 'json'
require 'stackmate/stack'
require 'stackmate/logging'
require 'stackmate/classmap'
require 'stackmate/participants/cloudstack'
require 'stackmate/participants/common'

Dir[File.dirname(__FILE__) + "/participants/*.rb"].each do |participant|
  if(participant.include?("cloudstack_"))
    require participant
  end
end

module StackMate

  class StackExecutor < StackMate::Stacker
    include Logging

    def initialize(templatefile, stackname, params, engine, create_wait_conditions, api_opts, timeout, plugins=nil, no_rollback=false)
      stackstr = File.read(templatefile)
      super(stackstr, stackname, resolve_param_refs(params, stackname))
      @engine = engine
      @create_wait_conditions = create_wait_conditions
      @api_opts = api_opts
      @timeout = timeout
      load_plugins(plugins)
      @rollback = !no_rollback
    end

    def load_plugins(plugins)
      if !plugins.nil?
        dirs = plugins.split(",")
        dirs.each do |dir|
          if(File.directory?(dir))
            Dir[dir+"/*.rb"].each do |file|
              begin
                existing_classes = ObjectSpace.each_object(Class).to_a
                require file
                new_classes =  ObjectSpace.each_object(Class).to_a
                added_classes = new_classes - existing_classes
                added_classes.each do |plugin_class|
                  if(plugin_class.class_variable_defined?(:@@stackmate_participant) && plugin_class.class_variable_get(:@@stackmate_participant) == true)
                    if(not(plugin_class.method_defined?(:consume_workitem) && plugin_class.ancestors.include?(Ruote::Participant)))
                      #http://stackoverflow.com/questions/1901884/loading-unloading-updating-class-in-ruby
                      #recursively get class name
                      namespace = plugin_class.name.split('::')[0..-2]
                      klass = plugin_class.name.split('::')[-1]
                      parent = Object
                      namespace.each do |p|
                        parent = parent.const_get(p.to_sym)
                      end
                      logger.debug("Removing bad participant defninition #{plugin_class} from #{parent}")
                      parent.send(:remove_const,klass.to_sym)
                    else
                      logger.debug("Adding method on_workitem to class #{plugin_class}")
                      plugin_class.class_eval do
                        def on_workitem
                          consume_workitem
                          reply
                        end
                      end
                    end
                  end
                end
              rescue Exception => e
                logger.error("Unable to load plugin #{file}. Dangling classes may exist!!")
              end
            end
          end
        end
      end
    end
    def resolve_param_refs(params, stackname)
      resolved_params = {}
      begin
        params.split(';').each do |p|
          i = p.split('=')
          resolved_params[i[0]] = i[1]
        end
      rescue
        #minimum parameters??
      end
      resolved_params['AWS::Region'] = 'us-east-1' #TODO handle this better
      resolved_params['AWS::StackName'] = stackname
      resolved_params['AWS::StackId'] = stackname
      resolved_params['CloudStack::StackName'] = stackname
      resolved_params['CloudStack::StackId'] = stackname
      resolved_params['CloudStack::StackMateApiURL'] = ENV['WAIT_COND_URL_BASE']?ENV['WAIT_COND_URL_BASE']:StackMate::WAIT_COND_URL_BASE_DEFAULT
      resolved_params
    end

    def pdef
      begin
        #participants = self.strongly_connected_components.flatten
        participants = self.tsort
      rescue Exception => e
        raise "ERROR: Cyclic Dependency detected! " + e.message
      end
      #if we want to skip creating wait conditions (useful for automated tests)
      participants = participants.select { |p|
        StackMate.class_for(@templ['Resources'][p]['Type']) != 'StackMate::WaitCondition'
      } if !@create_wait_conditions

      logger.info("Ordered list of participants: #{participants}")

      participants.each do |p|
        t = @templ['Resources'][p]['Type']
        throw :unknown, t if !StackMate.class_for(t)
        @engine.register_participant p, StackMate.class_for(t), @api_opts
      end
      timeout = @timeout + "s"
      @engine.register_participant 'Output', StackMate.class_for('Outputs')
      @engine.register_participant 'Notify', StackMate.class_for('StackMate::StackNotifier')
      @pdef = Ruote.define @stackname.to_s() do
        cursor :timeout => timeout, :on_error => 'rollback', :on_timeout => 'rollback' do
          participants.collect{ |name| __send__(name, :operation => :create) }
          __send__('Output')
        end
        define 'rollback', :timeout => timeout do
          __send__('Notify', :if => '${v:do_rollback}')
          participants.reverse_each.collect {|name| __send__(name, :operation => :rollback, :if => '${v:do_rollback}') }
        end
      end
    end

    def launch
      p @rollback
      wfid = @engine.launch(pdef, @templ, {'do_rollback' => @rollback})
      #wfid = @engine.launch(pdef, @templ)
      timeout = @timeout.to_i * 2
      @engine.wait_for(wfid, :timeout => timeout)
      logger.error { "engine error : #{@engine.errors.first.message}"} if @engine.errors.first
    end
  end

end
