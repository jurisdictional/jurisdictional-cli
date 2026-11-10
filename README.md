# jurisdictional

Command-line client for the Jurisdictional HTTP API.

## Install

The CLI needs Erlang/OTP 26 or newer (`brew install erlang` or `apt install erlang`).
Then install the latest release:

```bash
curl -fsSL https://github.com/afomi/jurisdictional-cli/releases/latest/download/install.sh | sh
jurisdictional juricode "Vacaville, CA"
```

The script checks the checksum, puts `jurisdictional` in `~/.local/bin`, and confirms it runs.
Set `JURISDICTIONAL_VERSION=v0.1.0` for a specific release, or `JURISDICTIONAL_INSTALL_DIR` for another folder.

## Release

The Release workflow builds the escript, runs the tests, publishes a GitHub release, and installs from it on Linux and macOS.
Bump `version` in `mix.exs`, push, then run it from the Actions tab or from here:

```bash
gh workflow run release.yml
gh run watch
```

## Build from source

```bash
mix deps.get
mix escript.build
./jurisdictional login
./jurisdictional juricode "Vacaville, CA"
./jurisdictional agencies list --jurisdiction 70118
```

The escript needs Erlang on the machine that runs it.
A later release can bundle the runtime.
`login` opens the browser, prints a short code, and waits for approval at `/device`.
It then writes `~/.jurisdictional/credentials.json` at mode 600.
It does not write `~/.jurisdictional/token`.
The CLI never asks for your password.
`--paste` redeems the refresh token the approval page shows once, for a terminal that cannot wait.
Type the token at the prompt, where it is not shown, or pipe it on stdin.
A token on the command line would stay in shell history, so `--paste` does not take one.

The verbs cover the JSON API.
`tool` calls whatever `GET /api/mcp/tools` lists.
`api` sends any other path.

`--save DIR` writes the response body into `DIR` and adds an entry to `DIR/index.json`.
The body file is the upstream JSON.
The index names the method, path, query, status, and the file.
Another app can read the index and open the file.
A response that contains an access token or a refresh token is not written.
`responses/` is a checked-in capture of public records for Vacaville.
See `responses/README.md`.
Those files are jurisdictions, agencies, bodies, meetings, people, and one boundary.
Activity counts and account settings belong to this app.
They are not part of that catalog.
A services read is not in the API yet.

Browser pages, LiveView, the sitemap, the license page, and the labs stay in the browser.
The device approval page stays in the browser.
Other OAuth redirects stay in the browser.
A CORS preflight is not a command.
`images person ID --image PATH` and `images jurisdiction ID --image PATH` upload an image file.
The client computes `image_sha256` from the file, which the server checks.
`contributions quick --photo PATH` attaches a photo.
Other flags go along as form fields; without a file, the body is JSON.
`POST /api/v1/juricode` is the same call as `juricode`.
Refreshing an access token happens inside the client.
There is no `/api/v1` services resource.
`agencies` does not look up a place name.
Run `juricode`, then pass that jurisdiction id.
