# frozen_string_literal: true

require "yaml"
require "json"
require "base64"
require "faraday"
require "async"
require "async/http/endpoint"
require "async/websocket/client"

require_relative "./message_protocol"
require_relative "./allowed_paths"

module Socket2Me
  class Client
    def initialize(config_path = File.expand_path("../config/client.yml", __dir__))
      @config = YAML.load_file(config_path)
      @username = @config.fetch("username")
      @token = @config.fetch("key")
      @server = @config.fetch("server")
      @websocket_url = @server.include?(":") ? "ws://#{@server}/ws" : "wss://#{@server}/ws"
      @local = @config.fetch("local")
      @allowed_paths = AllowedPaths.new(@local.fetch("allowed_paths", []))
    end

    def run
      @stop = false
      @connection = nil
      @reactor_task = nil

      Signal.trap("INT") do
        puts "Received INT signal, stopping"
        @stop = true
        # Wake up the reactor to check the stop flag
        @reactor_task&.reactor&.interrupt
      end

      Async do |task|
        @reactor_task = task
        until @stop
          endpoint = Async::HTTP::Endpoint.parse(@websocket_url)
          begin
            backoff = 1
            Async::WebSocket::Client.connect(endpoint) do |connection|
              @connection = connection
              send_ready

              # Heartbeat (start after ready)
              heartbeat = task.async do |heartbeat_task|
                until @stop do
                  begin
                    connection.write(JSON.dump(type: "ping", at: Time.now.to_i))
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
                  end
                end
              ensure
                monitor_task.stop
              end
            ensure
              heartbeat&.stop
              @connection = nil
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
      puts "Connecting to #{@server} as #{@username}"
      @connection.write(JSON.dump({
        type: "ready",
        username: @username,
        token: @token
      }))
    end

    def handle_request(msg)
      path = msg["path"]
      unless @allowed_paths.allow?(path)
        puts "Path not allowed: #{path}"
        @connection.write(
          JSON.dump(
            type: "response",
            id: msg["id"],
            status: 403,
            headers: {"Content-Type"=>"application/json"},
            body_b64: Base64.strict_encode64(JSON.dump(error: "path not allowed"))
          )
        )
        return
      end

      url = "#{@local.fetch("protocol")}://#{@local.fetch("host")}:#{@local.fetch("port")}#{path}"
      puts "Handling request: #{url}"
      method = msg["method"].to_s.downcase
      body = Base64.decode64(msg["body_b64"].to_s)
      headers = (msg["headers"].except("Host") || {})

      response = Faraday.run_request(method.to_sym, url, body.empty? ? nil : body, headers)
      resp_body = response.body.to_s
      payload = {
        type: "response",
        id: msg["id"],
        status: response.status,
        headers: response.headers,
        body_b64: Base64.strict_encode64(resp_body)
      }
      puts "Response:"
      pp payload.slice(:status, :headers)
      puts resp_body
      @connection.write(JSON.dump(payload))
    rescue StandardError => e
      err = {
        type: "response",
        id: msg["id"],
        status: 502,
        headers: {"Content-Type"=>"application/json"},
        body_b64: Base64.strict_encode64(JSON.dump(error: e.message)),
      }
      @connection.write(JSON.dump(err))
    end
  end
end

if $PROGRAM_NAME == __FILE__
  Socket2Me::Client.new.run
end


