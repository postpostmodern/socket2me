# frozen_string_literal: true

module Socket2Me
  module MessageProtocol
    module_function

    def b64_encode(bytes)
      Base64.strict_encode64(bytes.to_s)
    end

    def b64_decode(str)
      return "" if str.nil?
      Base64.decode64(str.to_s)
    rescue
      ""
    end
  end
end


