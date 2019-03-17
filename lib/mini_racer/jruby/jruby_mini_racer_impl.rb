require 'mini_racer/jruby/j2v8_linux_x86_64-4.8.0.jar'

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
    java_import com.eclipsesource.v8.V8
    java_import com.eclipsesource.v8.V8Array
    java_import com.eclipsesource.v8.V8Object
    java_import com.eclipsesource.v8.V8ScriptExecutionException

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
      @@v8 = V8::createV8Runtime
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
      JSToRuby(@@v8.execute_script(src, file, 0))
    end

    def call_unsafe(function_name, *arguments)
      arguments.map! { |arg| rubyToJS(arg) }
      JSToRuby(@@v8.execute_js_function(function_name, *arguments))
    rescue V8ScriptExecutionException => e
      raise(MiniRacer::RuntimeError, e.message.sub(/^[^:]*:\d+:\s*/, ''))
    end

    def rubyToJS(object)
      case object
      when Hash
        object.each_with_object(V8Object.new(@@v8)) { |(key, value), hash| hash.add rubyToJS(key), rubyToJS(value) }
      when Array
        object.each_with_object(V8Array.new(@@v8)) { |elt, array| array.push rubyToJS(elt) }
      when Symbol
        object.to_s
      else
        object
      end
    end

    def JSToRuby(object)
      return object unless object.respond_to? :getV8Type

      case object.getV8Type
      when com.eclipsesource.v8.V8Value::V8_OBJECT
        object.keys.each_with_object(Hash.new) { |key, hash| hash[key] = JSToRuby(object.get(key)) }
      when com.eclipsesource.v8.V8Value::V8_ARRAY
        array = []
        object.length.times do |index|
          array << JSToRubyArrayElement(object, index)
        end
        array
      else
        object
      end
    end

    def JSToRubyArrayElement(array, index)
      case array.type(index)
      when com.eclipsesource.v8.V8Value::INTEGER
        array.get_integer(index)
      when com.eclipsesource.v8.V8Value::STRING
        array.get_string(index)
      when com.eclipsesource.v8.V8Value::V8_ARRAY
        JSToRuby(array.get_array(index))
      when com.eclipsesource.v8.V8Value::V8_OBJECT
        JSToRuby(array.get_object(index))
      end
    end

    def notify_v8
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