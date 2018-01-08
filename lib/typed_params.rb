require "typed_params/version"
require "typed_contracts"
require "contracts"

module TypedParams
  class ParamsError < StandardError; end

  def self.included(base)
    base.include(::Contracts::Core)
    base.include(::Contracts::Builtin)
    base.extend(ClassMethods)

    def typed_params
      typed_fields = self.class.class_variable_get(:@@typed_fields)
      Params.new(params, typed_fields.fetch("#{controller_name}_controller_#{action_name}".to_sym, {}))
    end
  end

  module ClassMethods
    def typed_params(method, scheme)
      unless self.class_variables.include?(:@@typed_fields)
        class_variable_set(:@@typed_fields, {})
      end
      controller_class_name = to_s.underscore.to_sym
      typed_fields = self.class_variable_get(:@@typed_fields)
      class_variable_set(:@@typed_fields, typed_fields.merge("#{controller_class_name}_#{method}".to_sym => scheme))
    end
  end

  class Params
    include ::Contracts::Core
    include ::Contracts::Builtin
    include TypedContracts

    Contract Any, Hash => Any
    def initialize(base, schema)
      @schema = schema
      schema.map do |param_name, type|
        data = base[param_name]
        (class << self; self; end).send(:attr_reader, param_name)
        if type.is_a?(Hash)
          instance_variable_set("@#{param_name}", Params.new(data, type))
        else
          handle_non_hash(param_name, type, data)
        end
      end
    end

    Contract Hash => Hash
    def to_value_h(hsh = @schema)
      hsh.each_with_object({}) do |(k, _), acc|
        data = send(k)
        acc[k] = if data.is_a?(Params)
                   data.to_value_h
                 elsif data.class.in?([Kleisli::Maybe::Some, Kleisli::Maybe::None])
                   data.value
                 else
                   data
                 end
      end.compact
    end

    private

    Contract Symbol, RespondTo[:class], Any => Any
    def handle_non_hash(param_name, type, data)
      Contract.valid?(data, type)
      if maybe_of_and_not_wrapped?(type)
        handle_maybe_wrapping(param_name, type, data, presence: type.class == PresentMaybeOf)
      else
        raise ParamsError.new("Missing required parameter #{param_name}") if data.nil?
        instance_variable_set("@#{param_name}", data)
      end
    end

    Contract Any => Bool
    def maybe_of_and_not_wrapped?(type)
      type.class.in?([PresentMaybeOf, MaybeOf]) &&
        !type.class.in?([Kleisli::Maybe::Some, Kleisli::Maybe::None])
    end

    Contract Symbol, RespondTo[:class], Any, KeywordArgs[presence: Bool] => Any
    def handle_maybe_wrapping(param_name, type, data, presence:)
      data = data.permit!.to_h if data.is_a?(ActionController::Parameters)
      if data.is_a?(Hash)
        instance_variable_set("@#{param_name}", Params.new(data, type.vals.first))
      else
        maybe_data = presence ? data.presence.to_maybe : data.to_maybe
        instance_variable_set("@#{param_name}", maybe_data)
      end
    end
  end
end
