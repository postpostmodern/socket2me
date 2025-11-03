# Socket2Me

A simple Ruby-based HTTPS-to-local tunnel using a Rack WebSocket server and a Ruby client.

## Client

This repo contains the Socket2Me client. You can use it to connect to the public server at socket2me.dev, but
you'll have to contact me (socket2me@apperception.dev) to get a client account.

Or you can host your own Socket2Me server, which can be found at https://github.com/postpostmodern/socket2me-server.

### Installation

1. Clone this repo: `git clone https://github.com/postpostmodern/socket2me.git`
2. Ensure you have a recent version of Ruby and Bundler.
3. Bundle: `bundle install`

### Configuration

1. Create your config file: `cp config/client.exmaple.yml config/client.yml`
2. Edit `config/client.yml`
   - `username`: the username for your socket2me.dev client account
   - `key`: the key/password for your socket2me.dev client account
   - `server`: the public host of the socket2me-server
   - `local`: settings that determine where the client forwards requests
     - `protocol`: the protocol for connections to your local server (`http` or `https`)
     - `host`: the host for your local server (probably something like `localhost` or `lvh.me`)
     - `port`: the port for connections to your local server
     - `allowed_paths`: a yaml array of regex patterns to match request paths against
       - Something like `/.*` will allow any url to hit your server, but that's probably risky. If this is only for something like webhooks, add just the patterns that will match your webhook paths.

### Run

Run the client: `./socket2me`

Any https requests made to the server, where the subdomain matches your username, should get forwarded to your local host.
   
E.g.: If my username is `jason`, requests sent to `https://jason.socket2me.dev/` would get forwarded to my local server.

## Flow

- Server relays HTTP requests for `https://{username}.socket2me.dev/*` over WebSocket to the client.
- Client forwards to local server and returns the response.
