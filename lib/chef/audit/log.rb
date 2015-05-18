
require 'chef/client'
require 'chef/formatters/indentable_output_stream'
require 'chef/log'

class Chef
  class Audit
    class Log

      # TODO: when Chef::Config[:log_location] == Chef::Client::STDOUT_FD then we
      # get duplication ouput and we don't want that.
      # FIX IT FIX IT FIX IT

      def initialize
        @output = Chef::Formatters::IndentableOutputStream.new(Chef::Client::STDOUT_FD, Chef::Client::STDERR_FD)
      end

      def puts(msg = "")
        Chef::Log << "#{msg}\n"
        @output.puts_line(msg)
      end

    end
  end
end
