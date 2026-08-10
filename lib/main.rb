# frozen_string_literal: true

require "yaml"
require "json"
require "base64"
require "cgi"
require "faraday"
require "colorize"
require "async"
require "async/http/endpoint"
require "async/websocket/client"

require_relative "./allowed_paths"

module Socket2Me
  # Request headers that must never be forwarded to the local server. Host is
  # rewritten by Faraday; hop-by-hop headers are connection-specific; and the
  # X-Forwarded-*/X-Real-Ip/X-S2M-Username values are attacker-controllable over
  # the public tunnel, so a local app must not be able to trust them via us.
  STRIPPED_REQUEST_HEADERS = %w[
    host
    content-length
    connection
    keep-alive
    proxy-authenticate
    proxy-authorization
    te
    trailer
    transfer-encoding
    upgrade
    x-forwarded-for
    x-forwarded-host
    x-forwarded-proto
    x-real-ip
    x-s2m-username
  ].freeze

  class Client
    def initialize(verbose: false, config_path: File.expand_path("../config/client.yml", __dir__))
      @config = YAML.load_file(config_path)
      @verbose = verbose
      @username = @config.fetch("username")
      @token = @config.fetch("key")
      @server = @config.fetch("server")
      @server_host = "#{@username}.#{@server}"
      @websocket_url = "#{websocket_scheme}://#{@server_host}/ws"
      @local = @config.fetch("local")
      @allowed_paths = AllowedPaths.new(@local.fetch("allowed_paths", []))
    end

    # Default to encrypted wss. Only fall back to plaintext ws for a loopback
    # server (local development) or when the user explicitly opts in with
    # `insecure: true`. Previously any `server` containing ":" silently
    # downgraded to ws, so e.g. `server: example.com:443` sent the token and all
    # traffic in the clear.
    def websocket_scheme
      return "ws" if @config.fetch("insecure", false)

      host = @server.to_s.split(":").first.to_s
      loopback = %w[localhost 127.0.0.1 ::1 lvh.me].include?(host) || host.end_with?(".lvh.me", ".localhost")
      loopback ? "ws" : "wss"
    end

    def run
      @stop = false
      @connection = nil
      @heartbeat = nil
      @reactor_task = nil
      @stop_reader, @stop_writer = IO.pipe

      puts "Socket2Me Client Initializing...".green.bold
      puts "  Passthrough:     ".blue.bold + "https://#{@server_host}/" + "  ➤  ".yellow + "#{@local.fetch("protocol")}://#{@local.fetch("host")}:#{@local.fetch("port")}/"
      puts "  Allowed Paths:   ".blue.bold + @local.fetch("allowed_paths", []).join(", ")
      if @allowed_paths.empty?
        puts "\n"
        puts "  WARNING: no allowed_paths configured — ALL requests will be denied.".red.bold
        puts "  Add regex patterns under local.allowed_paths in config/client.yml.".red
      end
      puts "\n"

      Signal.trap("INT") do
        gracefully_exit
      end

      Async do |task|
        @reactor_task = task
        @backoff = 1

        # Monitor for stop signal
        task.async do
          @stop_reader.read
          cleanup
          task.stop
        end

        until @stop
          endpoint = Async::HTTP::Endpoint.parse(@websocket_url, alpn_protocols: ["http/1.1"])
          begin
            Async::WebSocket::Client.connect(endpoint) do |connection|
              @connection = connection
              authenticate
              # Reset backoff once we're connected and authenticated so a brief
              # drop after a long healthy session doesn't inherit a large delay.
              @backoff = 1

              # Heartbeat (start after successful auth)
              @heartbeat = task.async do |heartbeat_task|
                until @stop
                  begin
                    @connection.write(JSON.dump(type: "ping", id: SecureRandom.uuid, at: Time.now.to_i))
                    @connection.flush
                    heartbeat_task.sleep 15
                  rescue StandardError
                    break if @stop

                    raise
                  end
                end
              end

              # Main message loop
              while (raw = @connection.read)
                break if @stop

                msg = JSON.parse(raw)
                case msg["type"]
                when "request"
                  handle_request(msg)
                when "ping"
                  puts "Received ping: #{msg}"
                  @connection.write(JSON.dump(type: "pong", id: msg["id"]))
                  @connection.flush
                when "ready"
                  # Should not receive another ready message
                  puts "Unexpected ready message: #{msg}"
                when "pong"
                  # ignore for now
                when "error"
                  puts "ERROR: #{msg['message']}".red.bold
                  @stop = true
                  raise
                else
                  puts "Received unknown message: #{msg}"
                end
              end
            ensure
              cleanup
            end
          rescue StandardError => e
            cleanup
            break if @stop

            puts "Error: #{e.message}".red.bold
            puts "Backing off for #{@backoff} seconds"
            task.sleep(@backoff)
            @backoff = [@backoff * 2, 30].min
          end
        end
      end
    end

    private

    def cleanup
      @heartbeat&.stop
      @connection&.close
      @connection = nil
      @heartbeat = nil
    end

    def gracefully_exit
      print "\nClosing connection...".green
      @stop = true
      # Signal the stop pipe (safe from trap context)
      @stop_writer.write("stop")
      @stop_writer.close
      puts "Later, tater!".green.bold
    end

    def authenticate
      print "Connecting...\r"
      @connection.write(JSON.dump({
        type: "ready",
        username: @username,
        token: @token,
      }))
      @connection.flush

      auth_response = @connection.read
      auth_msg = JSON.parse(auth_response)

      case auth_msg.transform_keys(&:to_sym)
      in { type: "error", message: "unauthorized" }
        puts "Authorization failed. Please check your credentials in config/client.yml".red.bold
        gracefully_exit
      in { type: "error", message: message }
        puts "ERROR: #{message}".red.bold
        gracefully_exit
      in { type: "ready" }
        puts "Connection established to #{@websocket_url} as #{@username}"
        puts "Ready for requests! ".green.bold + "(ctrl-c to exit)\n"
      else
        puts "Unexpected auth response: #{auth_msg}".red.bold
        gracefully_exit
      end
    end

    def local_connection
      protocol, host, port = @local.fetch_values("protocol", "host", "port")
      options = @local.slice("ssl") || {}
      @local_connection ||= Faraday.new("#{protocol}://#{host}:#{port}", options) do |conn|
        # Bound how long a slow/hung local server can tie up a request. The
        # server gives up at 30s; keep the forward timeout at or below that.
        conn.options.open_timeout = Integer(@local.fetch("open_timeout", 5))
        conn.options.timeout = Integer(@local.fetch("timeout", 30))
      end
    end

    def handle_request(msg)
      path = msg["path"]
      id = msg["id"]
      return unless validate_path(path, id)

      method = msg["method"].to_s.downcase
      body = Base64.decode64(msg["body_b64"].to_s)
      headers = sanitize_headers(msg["headers"])

      puts "Handling request: ".blue + method.upcase.yellow.bold + " " + local_connection.build_url(path).to_s.yellow

      if @verbose
        puts ""
        puts ("=" * 60).green
        puts "Request Headers".green
        puts ("=" * 60).green
        pp headers
        puts ("=" * 60).green
        puts "Request Body".green
        puts ("=" * 60).green
        pp body
        puts "\n"
      end

      response = local_connection.run_request(method.to_sym, path, body.empty? ? nil : body, headers)
      resp_body = response.body.to_s
      payload = {
        type: "response",
        id: id,
        status: response.status,
        headers: response.headers,
        body_b64: Base64.strict_encode64(resp_body)
      }
      if @verbose
        puts ("=" * 60).green
        puts "Response Headers".green
        puts ("=" * 60).green
        pp payload.slice(:status, :headers)
        puts ("=" * 60).green
        puts "Response Body".green
        puts ("=" * 60).green
        puts resp_body
        puts "\n\n"
      end
      @connection.write(JSON.dump(payload))
      @connection.flush
    rescue StandardError => e
      puts "ERROR: #{e.message}".red.bold
      err = {
        type: "response",
        id: id,
        status: 502,
        headers: {"Content-Type"=>"application/json"},
        body_b64: Base64.strict_encode64(JSON.dump(error: e.message)),
      }
      @connection.write(JSON.dump(err))
      @connection.flush
    end

    def sanitize_headers(headers)
      (headers || {}).reject { |k, _| STRIPPED_REQUEST_HEADERS.include?(k.to_s.downcase) }
    end

    # Reject anything that could let an allowed prefix (e.g. ^/webhooks/.*) be
    # escaped via path traversal or control-character smuggling before the
    # local server normalizes it. Decodes twice to catch %2e%2e / %252e style
    # double-encoding.
    def suspicious_path?(path)
      decoded = path.to_s
      2.times { decoded = CGI.unescape(decoded) }
      return true if decoded.match?(/[\x00-\x1f\x7f]/) # control chars incl. CR/LF/NUL
      return true if decoded.include?("\\")

      segments = decoded.split(%r{[?#]}, 2).first.to_s.split("/")
      segments.include?("..")
    end

    def validate_path(path, id)
      return deny_path(path, id) if suspicious_path?(path)
      return true if @allowed_paths.allow?(path)

      deny_path(path, id)
    end

    def deny_path(path, id)
      puts "Path not allowed: ".red.bold + path.red
      @connection.write(
        JSON.dump(
          type: "response",
          id: id,
          status: 403,
          headers: {"Content-Type"=>"application/json"},
          body_b64: Base64.strict_encode64(JSON.dump(error: "path not allowed"))
        )
      )
      @connection.flush
      false
    end
  end
end

if $PROGRAM_NAME == __FILE__
  Socket2Me::Client.new.run
end
