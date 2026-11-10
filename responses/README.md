# Stored responses

These files are public responses from https://jurisdictional.org.
They were written by `jurisdictional --save responses`.
`index.json` names the method, path, query, status, file, `url`, `sha256`, and `captured_at` for each one.
`url` is the exact address that produced the file; `--save` does not follow redirects.
The file is the response body, unchanged aside from pretty-printed JSON.
`sha256` covers the pretty-printed file as written, not the bytes the server sent, so `shasum -a 256 FILE` checks it.
`license` appears only when the response declared one in a `Link: rel="license"` header.
It is copied as given and never inferred.
Another app can read the index and then open the file.

The example place is Vacaville, California.
The place id is 70118.
The city agency id is 13012.
The city council body id is 1.
One council member is person 1.

`activity` is not in this catalog.
It counts searches and contributions inside this app.
The response has no person, address, or IP.
It is still not a public record.
Do not publish it for other apps.

`geo layers` is public boundary data.
The body is about 2.6 MB, so it lives with each release instead of in git.
Fetch the latest copy from https://github.com/jurisdictional/jurisdictional-cli/releases/latest/download/geo-layers.json.
`SHA256SUMS` in the same release lists its checksum.
`jurisdictions scene` requires a token, so it is not here.
A login response is never saved.
Account routes such as `me`, devices, and sync are not here either.

Run the same command with `--save` when you want a fresh local copy of a public record.

These files are data, not code, so the repository's Apache license does not cover them.
They are under the Open Database License 1.0 in [LICENSE](LICENSE), and each record under the Database Contents License 1.0.
Credit Jurisdictional, and share a database you build from them under the ODbL.
A commercial license from Jurisdictional waives those terms for closed products.
A record can also carry facts from a source with its own terms, often named as a source URL in its text.
Check that source before you reuse the record.
