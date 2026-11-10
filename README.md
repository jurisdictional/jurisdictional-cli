# jurisdictional

Command-line client for the Jurisdictional HTTP API.

## Install

```bash
curl -fsSL https://github.com/afomi/jurisdictional-cli/releases/latest/download/install.sh | sh
jurisdictional juricode "Vacaville, CA"
```

On Linux (x86_64 and arm64) and Apple silicon Macs, the release carries its own Erlang runtime.
There is nothing else to install.
Linux needs glibc 2.35 or newer and OpenSSL 3, as on Ubuntu 22.04, Debian 12, and Fedora 36 and later.
Other systems get the escript, which needs Erlang/OTP 26 or newer (`brew install erlang`).

The script checks the checksum, puts the release in `~/.local/share/jurisdictional`, links `jurisdictional` into `~/.local/bin`, and confirms it runs.
Set `JURISDICTIONAL_VERSION=v0.1.0` for a specific release, or `JURISDICTIONAL_INSTALL_DIR` for another folder.

To install by hand, download `jurisdictional-<platform>.tar.gz` from the release page, unpack it, and run `jurisdictional/bin/jurisdictional`.
A Mac marks a browser download as quarantined; `xattr -dr com.apple.quarantine jurisdictional` clears it.

### In GitHub Actions

`examples/juricode-workflow.yml` installs the CLI and runs `juricode` for an address.
The job fails when the command exits with anything other than 0.
Copy it to `.github/workflows/` in your repository.
Each release also attaches it as `juricode-workflow.yml`.

## Release

The Release workflow runs the tests, builds the escript and a bundled release for each platform, and publishes them to GitHub.
It also attaches `geo-layers.json`, the public boundary layers, for other apps to fetch.
Then it installs from the published release on Ubuntu, macOS, and a clean Debian container with no Erlang.
Bump `version` in `mix.exs`, push, then run it from the Actions tab or from here:

```bash
gh workflow run release.yml
gh run watch
```

## Build from source

```bash
mix deps.get
mix escript.build                 # ./jurisdictional, needs Erlang to run
MIX_ENV=prod mix release          # _build/prod/rel/jurisdictional_cli, carries its own runtime
./jurisdictional login
./jurisdictional juricode "Vacaville, CA"
./jurisdictional agencies list --jurisdiction 70118
```

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

## Contributing

```bash
mix deps.get
mix precommit
```

`mix precommit` formats the code, then runs Credo, Dialyzer, and the tests, including the property tests in `test/property_test.exs`.
CI runs the same checks on every push and pull request.
The Credo limits on nesting and complexity in `.credo.exs` match today's worst function.
Lower them as the command dispatch is split up.

