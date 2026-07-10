# Logavo Server

Elixir/Phoenix server for logavo — a log collection and monitoring tool for
local development. It receives normalized log entries from the Rust agent,
stores them in SQLite, and will serve a LiveView dashboard (see
`docs/spec.md` in the repository root for the full specification).

## Getting started

To start your Phoenix server:

  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Tests

```sh
mix deps.get
mix test
```

## Learn more

  * Official website: https://www.phoenixframework.org/
  * Guides: https://hexdocs.pm/phoenix/overview.html
  * Docs: https://hexdocs.pm/phoenix
  * Forum: https://elixirforum.com/c/phoenix-forum
  * Source: https://github.com/phoenixframework/phoenix
