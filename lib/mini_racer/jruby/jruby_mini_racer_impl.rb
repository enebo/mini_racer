require 'mini_racer/jruby/j2v8_linux_x86_64-4.8.0.jar'
require 'mini_racer/jruby/converters'

module MiniRacer
  class Error < ::StandardError; end

  class ContextDisposedError < Error; end
  class SnapshotError < Error; end
  class PlatformAlreadyInitialized < Error; end

  class EvalError < Error; end
  class ParseError < EvalError; end
  class ScriptTerminatedError < EvalError; end
  class V8OutOfMemoryError < EvalError; end

  class FailedV8Conversion
    attr_reader :info
    def initialize(info)
      @info = info
    end
  end

  class RuntimeError < EvalError
    def initialize(message)
      message, js_backtrace = message.split("\n", 2)
      if js_backtrace && !js_backtrace.empty?
        @js_backtrace = js_backtrace.split("\n")
        @js_backtrace.map!{|f| "JavaScript #{f.strip}"}
      else
        @js_backtrace = nil
      end
      super(message)
    end

    def backtrace
      val = super
      return unless val
      if @js_backtrace
        @js_backtrace + val
      else
        val
      end
    end
  end

  # helper class returned when we have a JavaScript function
  class JavaScriptFunction
    def to_s
      "JavaScript Function"
    end
  end

  class Context
    java_import com.eclipsesource.v8.NodeJS
    java_import com.eclipsesource.v8.V8
    java_import com.eclipsesource.v8.V8ScriptExecutionException

    include MiniRacer::Converters

    class ExternalFunction
      def initialize(name, callback, parent)
        unless String === name
          raise ArgumentError, "parent_object must be a String"
        end
        parent_object, _ , @name = name.rpartition(".")
        @callback = callback
        @parent = parent

        build_parent_object_eval(parent_object)

        puts "PARENT_IOB: #{parent_object}"
        if parent_object.empty?
          parent.register(nil, @name, callback)
        else
          parent.register(parent.v8.executeObjectScript(@parent_object_eval), @name, callback)
        end
      end

      private

      def build_parent_object_eval(parent_object)
        unless parent_object.empty?
          @parent_object = parent_object

          @parent_object_eval = ""
          prev = ""
          first = true
          parent_object.split(".").each do |obj|
            prev << obj
            if first
              @parent_object_eval << "if (typeof #{prev} === 'undefined') { #{prev} = {} };\n"
            else
              @parent_object_eval << "#{prev} = #{prev} || {};\n"
            end
            prev << "."
            first = false
          end
          @parent_object_eval << "#{parent_object};"
        end
      end
    end

    def v8
      @@v8
    end

    def initialize(options = nil)
      options ||= {}

      check_init_options!(options)

      @functions = {}
      @timeout = nil
      @max_memory = nil
      @current_exception = nil
      @timeout = options[:timeout]
      if options[:max_memory].is_a?(Numeric) && options[:max_memory] > 0
        @max_memory = options[:max_memory]
      end
      # false signals it should be fetched if requested
      @isolate = options[:isolate] || false
      @disposed = false

      @callback_mutex = Mutex.new
      @callback_running = false
      @thread_raise_called = false
      @eval_thread = nil

      # defined in the C class
      init_unsafe(options[:isolate], options[:snapshot])
    end


    def init_unsafe(isolate, snapshot)
      #v8 = V8::createV8Runtime
      @@nodejs ||= NodeJS.createNodeJS
      @@v8 ||= @@nodejs.runtime
    end

    def eval(str, options=nil)
      raise(ContextDisposedError, 'attempted to call eval on a disposed context!') if @disposed

      filename = options && options[:filename].to_s

      @eval_thread = Thread.current
      @current_exception = nil
      #timeout do
        eval_unsafe(str, filename)
      #end
    ensure
      @eval_thread = nil
    end

    def load(filename)
      # TODO do this native cause no need to allocate VALUE here
      eval(File.read(filename))
    end

    def call(function_name, *arguments)
      raise(ContextDisposedError, 'attempted to call function on a disposed context!') if @disposed

      @eval_thread = Thread.current
#      isolate_mutex.synchronize do
#        timeout do
          call_unsafe(function_name, *arguments)
#        end
#      end
    ensure
      @eval_thread = nil
    end

    def eval_unsafe(src, file)
      puts "EVAL_UNSAFE: #{src}"
      JSToRuby(@@v8.execute_script(src, file, 0))
    end

    def call_unsafe(function_name, *arguments)
      arguments.map! { |arg| rubyToJS(context, arg) }
      JSToRuby(@@v8.execute_js_function(function_name, *arguments))
    rescue V8ScriptExecutionException => e
      raise(MiniRacer::RuntimeError, e.message.sub(/^[^:]*:\d+:\s*/, ''))
    end

    class Runner
      include com.eclipsesource.v8.JavaCallback

      include MiniRacer::Converters

      def initialize(context, callback)
        @context, @callback = context, callback
      end

      def invoke(reciever, params)
        params = JSToRuby(params)
        puts "IN INVOKE: #{params}"
        result = @callback[*params]
        puts "RESULT: #{result} #{result.class}"
        js_result = rubyToJS(@context, result)
        puts "JSRESULT: #{js_result} #{js_result.class}"
        #arr = com.eclipsesource.v8.V8Array.new(@context)
        #arr.push(js_result)
        #arr
        #
      end
    end

    def attach(name, callback)
      raise(ContextDisposedError, 'attempted to call function on a disposed context!') if @disposed

      wrapped = lambda do |*args|
        begin

          r = nil

          begin
            @callback_mutex.synchronize{
              @callback_running = true
            }
            r = callback.call(args)
          ensure
            @callback_mutex.synchronize{
              @callback_running = false
            }
          end

          # wait up to 2 seconds for this to be interrupted
          # will very rarely be called cause #raise is called
          # in another mutex
          @callback_mutex.synchronize {
            if @thread_raise_called
              sleep 2
            end
          }

          r
        ensure
          @callback_mutex.synchronize {
            @thread_raise_called = false
          }
        end
      end

      #isolate_mutex.synchronize do
        external = ExternalFunction.new(name, wrapped, self)
        @functions["#{name}"] = external
      #end
    end

    def register(parent, name, callback)
      if parent
        parent.registerJavaMethod(Runner.new(@@v8, callback), name)
      else
        @@v8.registerJavaMethod(Runner.new(@@v8, callback), name)
      end
    end

    def dispose
      return if @disposed
      @disposed = true
      @isolate = nil # allow it to be garbage collected, if set
    end

    def check_init_options!(options)
      #assert_option_is_nil_or_a('isolate', options[:isolate], Isolate)
      #assert_option_is_nil_or_a('snapshot', options[:snapshot], Snapshot)

      if options[:isolate] && options[:snapshot]
        raise ArgumentError, 'can only pass one of isolate and snapshot options'
      end
    end

    def assert_option_is_nil_or_a(option_name, object, klass)
      unless object.nil? || object.is_a?(klass)
        raise ArgumentError, "#{option_name} must be a #{klass} object, passed a #{object.inspect}"
      end
    end

  end

  class Isolate
    def initialize(snapshot = nil)
      unless snapshot.nil? || snapshot.is_a?(Snapshot)
        raise ArgumentError, "snapshot must be a Snapshot object, passed a #{snapshot.inspect}"
      end

      # defined in the C class
      init_with_snapshot(snapshot)
    end
  end

  class Platform
    class << self
      def set_flag_as_str!(flag)
      end

      def set_flags!(*args, **kwargs)
        flags_to_strings([args, kwargs]).each do |flag|
          # defined in the C class
          set_flag_as_str!(flag)
        end
      end

      private

      def flags_to_strings(flags)
        flags.flatten.map { |flag| flag_to_string(flag) }.flatten
      end

      # normalize flags to strings, and adds leading dashes if needed
      def flag_to_string(flag)
        if flag.is_a?(Hash)
          flag.map do |key, value|
            "#{flag_to_string(key)} #{value}"
          end
        else
          str = flag.to_s
          str = "--#{str}" unless str.start_with?('--')
          str
        end
      end

    end
  end
end
