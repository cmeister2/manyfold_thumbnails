# frozen_string_literal: true

# Manyfold's installed Minitest supplies the runner without minitest/mock.
module TemporaryMethod
  def with_temporary_method(target, name, replacement)
    singleton = target.singleton_class
    own_method = singleton.instance_methods(false).include?(name)
    original = target.method(name) if target.respond_to?(name)
    target.define_singleton_method(name, replacement)
    yield
  ensure
    if own_method
      target.define_singleton_method(name, original)
    else
      singleton.remove_method(name)
    end
  end
end
