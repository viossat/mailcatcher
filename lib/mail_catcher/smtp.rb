module MailCatcher
  module SMTP
    require 'uri'
    require 'async/io/endpoint'
    require 'async/io/host_endpoint'
    require 'async/io/ssl_endpoint'

    class URLEndpoint < Async::IO::Endpoint
      def self.parse(string, **options)
        url = URI.parse(string).normalize

        self.new(url, **options)
      end

      def initialize(url, endpoint = nil, **options)
        super(**options)

        raise ArgumentError.new("URL must be absolute (include scheme, host): #{url}") unless url.absolute?

        @url = url
        @endpoint = endpoint
      end

      def to_s
        "\#<#{self.class} #{@url} #{@options.inspect}>"
      end

      attr :url
      attr :options

      def address
        endpoint.address
      end

      def secure?
        ['smtps'].include?(@url.scheme)
      end

      def protocol
        Protocol::SMTP
      end

      def default_port
        secure? ? 465 : 25
      end

      def default_port?
        port == default_port
      end

      def port
        @options[:port] || @url.port || default_port
      end

      def hostname
        @options[:hostname] || @url.hostname
      end

      def scheme
        @options[:scheme] || @url.scheme
      end

      def authority
        if default_port?
          hostname
        else
          "#{hostname}:#{port}"
        end
      end

      def path
        @url.request_uri
      end

      LOCALHOST = 'localhost'.freeze

      # We don't try to validate peer certificates when talking to localhost because they would always be self-signed.
      def ssl_verify_mode
        case self.hostname
        when LOCALHOST
          OpenSSL::SSL::VERIFY_NONE
        else
          OpenSSL::SSL::VERIFY_PEER
        end
      end

      def ssl_context
        @options[:ssl_context] || ::OpenSSL::SSL::SSLContext.new.tap do |context|
          context.set_params(
            verify_mode: self.ssl_verify_mode
          )
        end
      end

      def tcp_options
        {reuse_port: @options[:reuse_port] ? true : false}
      end

      def build_endpoint(endpoint = nil)
        endpoint ||= Async::IO::Endpoint.tcp(hostname, port, tcp_options)

        if secure?
          # Wrap it in SSL:
          return Async::IO::SSLEndpoint.new(endpoint,
            ssl_context: self.ssl_context,
            hostname: self.hostname
          )
        end

        return endpoint
      end

      def endpoint
        @endpoint ||= build_endpoint
      end

      def bind(*args, &block)
        endpoint.bind(*args, &block)
      end

      def connect(*args, &block)
        endpoint.connect(*args, &block)
      end

      def each
        return to_enum unless block_given?

        self.endpoint.each do |endpoint|
          yield self.class.new(@url, endpoint, @options)
        end
      end

      def key
        [@url.scheme, @url.userinfo, @url.host, @url.port, @options]
      end

      def eql? other
        self.key.eql? other.key
      end

      def hash
        self.key.hash
      end
    end

    class Envelope
      def initialize
        @sender = nil
        @recipients = []
        @encoding = :utf8 # utf-8 by default
        @content = "".b
      end

      attr_accessor :sender
      attr_accessor :recipients
      attr_accessor :encoding
      attr_accessor :content
    end

    require 'async/io/protocol/line'

    module Protocol
      module SMTP
        def self.server(stream, *args)
          Server.new(stream, *args)
        end

        class Server < Async::IO::Protocol::Line
          CR = "\r".freeze
          LF = "\n".freeze
          CRLF = "\r\n".freeze
          SP = " ".freeze
          COLON = ":".freeze
          DOT = ".".freeze

          def initialize(stream, hostname: nil)
            super(stream, CRLF)

            @hostname = hostname
          end

          attr :hostname

          def read_line
            if line = @stream.read_until(LF)
              line.chomp(CR)
            else
              @stream.eof!
            end
          end

          alias_method :write_line, :write_lines

          def write_response(code, *lines, last_line)
            write_lines *lines.map { |line| "#{code}-#{line}" },
              "#{code} #{last_line}"
          end

          def each(task: Async::Task.current)
            write_response 220, "MailCatcher ready"

            envelope = nil

            loop do
              line = read_line
              command, line = line.split(SP, 2)
              case command
              when "HELO"
                write_response 250, hostname
              when "EHLO"
                write_response 250, hostname, "8BITMIME", "SMTPUTF8", "CHUNKING"
              when "SEND"
                write_response 502, "Command not implemented"
              when "SOML"
                write_response 502, "Command not implemented"
              when "SAML"
                write_response 502, "Command not implemented"
              when "MAIL"
                from, line = line.split(COLON, 2)
                unless from == "FROM"
                  write_response 500, "Syntax error, command unrecognized"
                  next
                end
                sender, line = line.split(SP, 2)
                envelope = Envelope.new
                envelope.sender = sender
                if line && !line.empty?
                  line.split(SP).each do |param|
                    case param
                    when "BODY=7BIT"
                      envelope.encoding = :ascii
                    when "BODY=8BITMIME"
                      envelope.encoding = :binary
                    when "SMTPUTF8"
                      envelope.encoding = :utf8
                    else
                      write_response 501, "Syntax error in parameters or arguments"
                    end
                  end
                end
                write_response 250, "New message from: #{sender}"
              when "RCPT"
                unless envelope
                  write_response 503, "Bad sequence of commands"
                  next
                end
                to, line = line.split(COLON, 2)
                unless to == "TO"
                  write_response 501, "Syntax error in parameters or arguments"
                  next
                end
                recipient, line = line.split(SP, 2)
                if line && !line.empty?
                  write_response 501, "Syntax error in parameters or arguments"
                  next
                end
                envelope.recipients << recipient
                write_response 250, "Recipient added: #{recipient}"
              when "DATA"
                unless envelope
                  write_response 503, "Bad sequence of commands"
                  next
                end
                unless envelope.content.empty? # BDAT?
                  write_response 503, "Bad sequence of commands"
                  next
                end
                if line && !line.empty?
                  write_response 501, "Syntax error in parameters or arguments"
                  next
                end
                write_response 354, "Start mail input; end with <CRLF>.<CRLF>"
                loop do
                  line = read_line
                  break if line == DOT
                  line.delete_prefix!(DOT)
                  envelope.content << line << CRLF
                  task.yield
                end
                begin
                  case envelope.encoding
                  when :ascii
                    envelope.content.force_encoding(Encoding::ASCII)
                  when :binary
                    envelope.content.force_encoding(Encoding::BINARY)
                  when :utf8
                    envelope.content.force_encoding(Encoding::UTF_8)
                  end
                rescue ArgumentError => e
                  write_response 500, "Bad encoding: #{e.to_s}"
                  envelope = nil
                  next
                end
                yield envelope
                envelope = nil
                write_response 250, "OK"
              when "BDAT"
                unless envelope
                  write_response 503, "Bad sequence of commands"
                  next
                end
                size, line = line.split(SP, 2)
                unless size.to_i.to_s == size
                  write_response 501, "Syntax error in parameters or arguments"
                  next
                end
                size = size.to_i
                last = false
                if line == "LAST"
                  last = true
                elsif line && !line.empty?
                  write_response 501, "Syntax error in parameters or arguments"
                  next
                end
                envelope.content << read(size)
                if last
                  begin
                    case envelope.encoding
                    when :ascii
                      envelope.content.force_encoding(Encoding::ASCII)
                    when :binary
                      envelope.content.force_encoding(Encoding::BINARY)
                    when :utf8
                      envelope.content.force_encoding(Encoding::UTF_8)
                    end
                  rescue ArgumentError => e
                    write_response 500, "Bad encoding: #{e.to_s}"
                    envelope = nil
                    next
                  end
                  yield envelope
                  envelope = nil
                end
                write_response 250, "OK"
              when "RSET"
                if line && !line.empty?
                  write_response 501, "Syntax error in parameters or arguments"
                  next
                end
                envelope = nil
                write_response 250, "OK"
              when "NOOP"
                if line && !line.empty?
                  write_response 501, "Syntax error in parameters or arguments"
                  next
                end
                write_response 250, "OK"
              when "EXPN"
                write_response 502, "Command not implemented"
              when "VRFY"
                write_response 502, "Command not implemented"
              when "HELP"
                write_response 502, "Command not implemented"
              when "STARTTLS"
                write_response 502, "Command not implemented"
              when "QUIT"
                if line && !line.empty?
                  write_response 501, "Syntax error in parameters or arguments"
                  next
                end
                write_response 221, "Bye!"
                close unless closed?
                return
              else
                write_response 500, "Syntax error, command unrecognized"
              end

              task.yield
            end

            close unless closed?
          end
        end
      end
    end

    require 'async'
    require 'async/task'
    require 'async/io/stream'

    class Server
      def initialize(endpoint, protocol = endpoint.protocol)
        @endpoint = endpoint
        @protocol = protocol

        if block_given?
          define_singleton_method(:call, &proc)
        end
      end

      def accept(peer, address, task: Async::Task.current)
        Async.logger.debug(self) {"Incoming connnection from #{address.inspect}"}

        stream = Async::IO::Stream.new(peer)
        protocol = @protocol.server(stream, hostname: @endpoint.hostname)

        protocol.each do |envelope|
          Async.logger.debug(self) {"Incoming message from #{address.inspect}: #{envelope.inspect}"}

          self.call(envelope)
        end

        Async.logger.debug(self) {"Connection from #{address.inspect} closed cleanly"}
      rescue EOFError, Errno::ECONNRESET, Errno::EPIPE, Errno::EPROTOTYPE
        # Sometimes client will disconnect without completing a result or reading the entire buffer. That means we are done.
        # Errno::EPROTOTYPE is a bug with Darwin. It happens because the socket is lazily created (in Darwin).
        Async.logger.debug(self) {"Connection from #{address.inspect} closed: #{$!}"}
      end

      def call
        raise NotImplementedError, "Supply a block to MailCatcher::SMTP::Server.new or subclass and implement #call"
      end

      def run
        @endpoint.accept(&method(:accept))
      end
    end
  end
end
