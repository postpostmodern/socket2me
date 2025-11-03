# frozen_string_literal: true

module Socket2Me
  class AllowedPaths
    def initialize(patterns)
      @patterns = Array(patterns).map do |pattern|
        if pattern.is_a?(Regexp)
          pattern
        else
          Regexp.new(pattern.to_s)
        end
      rescue RegexpError => e
        raise ArgumentError, "Invalid regex pattern in allowed_paths: #{pattern.inspect} - #{e.message}"
      end
    end

    def allow?(path)
      return true if @patterns.empty?

      @patterns.any? { |regex| regex.match?(path) }
    end
  end
end


