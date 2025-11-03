# socket2me

A simple Ruby-based HTTPS-to-local tunnel using a Rack WebSocket server and a Ruby client.

## Client

- Configure `config/client.yml` with your username, key, server, and local target.

Run:

```bash
./socket2me
```

## Flow

- Server relays HTTP requests to `https://{username}.socket2me.dev/*` over WebSocket to the client.
- Client forwards to local server and returns the response.
