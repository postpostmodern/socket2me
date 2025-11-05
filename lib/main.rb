# frozen_string_literal: true

require "yaml"
require "json"
require "base64"
require "faraday"
require "colorize"
require "async"
require "async/http/endpoint"
require "async/websocket/client"

require_relative "./allowed_paths"

module Socket2Me
  class Client
    def initialize(verbose: false, config_path: File.expand_path("../config/client.yml", __dir__))
      @config = YAML.load_file(config_path)
      @verbose = verbose
      @username = @config.fetch("username")
      @token = @config.fetch("key")
      @server = @config.fetch("server")
      @server_host = "#{@username}.#{@server}"
      @websocket_url = @server.include?(":") ? "ws://#{@server_host}/ws" : "wss://#{@server_host}/ws"
      @local = @config.fetch("local")
      @allowed_paths = AllowedPaths.new(@local.fetch("allowed_paths", []))
    end

    def run
      @stop = false
      @connection = nil
      @reactor_task = nil

      puts "Socket2Me Client Initializing...".green.bold
      puts "  Passthrough:     ".blue.bold + "https://#{@server_host}/" + "  ➤  ".yellow + "#{@local.fetch("protocol")}://#{@local.fetch("host")}:#{@local.fetch("port")}/"
      puts "  Allowed Paths:   ".blue.bold + @local.fetch("allowed_paths", []).join(", ")
      puts "\n"

      Signal.trap("INT") do
        print "\nClosing connection...".green
        @stop = true
        # Wake up the reactor to check the stop flag
        @reactor_task&.reactor&.interrupt
      end

      Async do |task|
        @reactor_task = task
        until @stop
          endpoint = Async::HTTP::Endpoint.parse(@websocket_url, alpn_protocols: ["http/1.1"])
          begin
            backoff = 1
            Async::WebSocket::Client.connect(endpoint) do |connection|
              @connection = connection
              send_ready

              # Heartbeat (start after ready)
              heartbeat = task.async do |heartbeat_task|
                until @stop do
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

              # Monitor for stop signal and close connection from reactor context
              monitor_task = task.async do |monitor_task|
                until @stop
                  monitor_task.sleep(0.5)
                end
                # Close connection from reactor context (safe)
                @connection&.close if @stop
              end

              begin
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
                    print "\rConnection established to #{@websocket_url} as #{@username}\n"
                    puts "Ready for requests! ".green.bold + "(ctrl-c to exit)\n"
                  when "pong"
                    # ignore for now
                  else
                    puts "Received unknown message: #{msg}"
                  end
                end
              ensure
                monitor_task.stop
              end
            ensure
              heartbeat&.stop
              @connection = nil
              puts "Goodbye!\n".green.bold
            end
          rescue StandardError => e
            break if @stop
            puts "Error: #{e.message}"
            puts "Backing off for #{backoff} seconds"
            task.sleep(backoff)
            backoff = [backoff * 2, 30].min
          end
        end
      end
    end

    private

    def send_ready
      print "Connecting..."
      @connection.write(JSON.dump({
        type: "ready",
        username: @username,
        token: @token
      }))
      @connection.flush
    end

    def handle_request(msg)
      path = msg["path"]
      unless @allowed_paths.allow?(path)
        puts "Path not allowed: ".red.bold + path.red
        @connection.write(
          JSON.dump(
            type: "response",
            id: msg["id"],
            status: 403,
            headers: {"Content-Type"=>"application/json"},
            body_b64: Base64.strict_encode64(JSON.dump(error: "path not allowed"))
          )
        )
        @connection.flush
        return
      end

      url = "#{@local.fetch("protocol")}://#{@local.fetch("host")}:#{@local.fetch("port")}#{path}"
      method = msg["method"].to_s.downcase
      body = Base64.decode64(msg["body_b64"].to_s)
      headers = (msg["headers"].except("Host") || {})

      puts "Handling request: ".blue + method.upcase.yellow.bold + " " + url.yellow

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

      response = Faraday.run_request(method.to_sym, url, body.empty? ? nil : body, headers)
      resp_body = response.body.to_s
      payload = {
        type: "response",
        id: msg["id"],
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
      err = {
        type: "response",
        id: msg["id"],
        status: 502,
        headers: {"Content-Type"=>"application/json"},
        body_b64: Base64.strict_encode64(JSON.dump(error: e.message)),
      }
      @connection.write(JSON.dump(err))
      @connection.flush
    end
  end
end

if $PROGRAM_NAME == __FILE__
  Socket2Me::Client.new.run
end
