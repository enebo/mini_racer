module MiniRacer
  module Converters
    java_import com.eclipsesource.v8.V8Array
    java_import com.eclipsesource.v8.V8Object
    java_import com.eclipsesource.v8.V8Value

    def rubyToJS(context, object)
      case object
      when Hash
        object.each_with_object(V8Object.new(context)) { |(key, value), hash| hash.add rubyToJS(context, key), rubyToJS(context, value) }
      when Array
        object.each_with_object(V8Array.new(context)) { |elt, array| array.push rubyToJS(context, elt) }
      when Symbol
        object.to_s
      else
        object
      end
    end

    def JSToRuby(object)
      return object unless object.respond_to? :getV8Type

      case object.getV8Type
      when V8Value::V8_OBJECT
        object.keys.each_with_object(Hash.new) { |key, hash| hash[key] = JSToRuby(object.get(key)) }
      when V8Value::V8_ARRAY
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
      when V8Value::INTEGER
        array.get_integer(index)
      when V8Value::STRING
        array.get_string(index)
      when V8Value::V8_ARRAY
        JSToRuby(array.get_array(index))
      when V8Value::V8_OBJECT
        JSToRuby(array.get_object(index))
      end
    end
  end
end