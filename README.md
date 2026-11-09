# jurisdictional

Command-line client for the Jurisdictional HTTP API.

```bash
mix escript.build
./jurisdictional login
./jurisdictional juricode "Vacaville, CA"
./jurisdictional agencies list --jurisdiction 70118
```

The escript needs Erlang on the machine that runs it.
A later release can bundle the runtime.
`login` writes `~/.jurisdictional/credentials.json` at mode 600.
It does not write `~/.jurisdictional/token`.
