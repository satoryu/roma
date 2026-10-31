module Roma
  module Tools
    # Raised by a tool when it can't do its work, such as on bad arguments.
    # The roma command prints the message and exits with status 1.
    class Error < StandardError; end
  end
end
