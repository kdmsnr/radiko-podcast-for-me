class MiniExiftool
  class Error < StandardError; end

  @data = {}

  class << self
    def register(path, attributes)
      store[path] = attributes
    end

    def reset
      @data = {}
    end

    def store
      @data ||= {}
    end
  end

  def initialize(path, ignore_minor_errors: true)
    @attributes = self.class.store.fetch(path) do
      raise Errno::ENOENT, path
    end
  end

  def method_missing(name, *args, &block)
    return @attributes[name] if @attributes.key?(name)
    nil
  end

  def respond_to_missing?(_name, _include_private = false)
    true
  end
end
