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

The verbs cover the JSON API.
`tool` calls whatever `GET /api/mcp/tools` lists.
`api` sends any other path.

Browser pages, LiveView, the sitemap, the license page, and the labs stay in the browser.
Browser sign-in and the OAuth redirects stay in the browser.
A CORS preflight is not a command.
An image file and a contribution photo go up as multipart, which this client does not send.
A JSON image record, and a contribution without a photo, do go up.
`POST /api/v1/juricode` is the same call as `juricode`.
Refreshing an access token happens inside the client.
There is no `/api/v1` services resource.
`agencies` does not look up a place name.
Run `juricode`, then pass that jurisdiction id.
