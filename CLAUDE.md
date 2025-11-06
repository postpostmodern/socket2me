# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Socket2Me is a Ruby-based HTTPS-to-local tunnel client that connects to a Socket2Me server (separate repo at https://github.com/postpostmodern/socket2me-server). It uses WebSocket connections to relay HTTP requests from a public server to a local development environment.

**Flow**: Server relays HTTP requests for `https://{username}.socket2me.dev/*` over WebSocket → Client forwards to local server → Returns response.

## Development Commands

### Setup
```bash
bundle install
cp config/client.example.yml config/client.yml
# Edit config/client.yml with your credentials and local server settings
```

### Running the Client
```bash
./socket2me              # Run normally
./socket2me --verbose    # Print local response bodies for debugging
./socket2me --help       # Show usage
```

### Linting
```bash
bundle exec rubocop
```

## Architecture

### Core Components

**Entry Point** (`socket2me`):
- Executable script that parses CLI options (verbose mode) and initializes `Socket2Me::Client`

**Main Client** (`lib/main.rb`):
- `Socket2Me::Client` class handles the entire WebSocket lifecycle
- Configuration loaded from `config/client.yml` (YAML format)
- Uses `async` and `async-websocket` gems for concurrent I/O operations
- Establishes WebSocket connection to `wss://{username}.{server}/ws`

**Key Client Behaviors**:
- **Authentication**: Sends `ready` message with username/token on connection
- **Heartbeat**: Pings server every 15 seconds to keep connection alive
- **Exponential Backoff**: Reconnects with backoff (1s → 2s → 4s → ... max 30s) on failures
- **Graceful Shutdown**: Traps INT signal (ctrl-c) to close connection cleanly
- **Request Handling**: 
  - Receives requests as JSON with Base64-encoded bodies
  - Validates paths against allowed patterns
  - Forwards to local server via Faraday HTTP client
  - Returns responses as JSON with Base64-encoded bodies

**Path Validation** (`lib/allowed_paths.rb`):
- `AllowedPaths` class validates incoming request paths against regex patterns
- Configured via `allowed_paths` array in config (e.g., `^/webhooks/.*`)
- Returns 403 for disallowed paths as a security measure

### Message Protocol

WebSocket messages use JSON with these types:
- `ready`: Client → Server (authentication with username/token)
- `request`: Server → Client (HTTP request with method, path, headers, Base64 body)
- `response`: Client → Server (HTTP response with status, headers, Base64 body)
- `ping`/`pong`: Bidirectional heartbeat
- `error`: Server → Client (e.g., "unauthorized")

### Configuration Structure

`config/client.yml`:
```yaml
username: <string>       # Server account username
key: <string>            # Server account password/token
server: <string>         # Server hostname (e.g., "socket2me.dev")
local:
  protocol: http|https   # Local server protocol
  host: <string>         # Local server host (e.g., "localhost")
  port: <integer>        # Local server port
  allowed_paths:         # Array of regex patterns
    - <regex_string>
  ssl:                   # Faraday SSL options (optional)
    verify: true|false   # Set false for self-signed certs
```

## Code Style

RuboCop configuration (`.rubocop.yml`):
- Double quotes for strings
- Fixed indentation for arguments
- Indented multiline method calls
- Trailing commas in multiline arrays/hashes/arguments

## Dependencies

Key gems:
- `async` / `async-websocket`: Asynchronous WebSocket client
- `faraday` / `faraday-multipart`: HTTP client for local forwarding
- `oj`: Fast JSON parsing
- `colorize`: Terminal output formatting
