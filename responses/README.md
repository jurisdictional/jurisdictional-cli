# Stored responses

These files are public responses from https://jurisdictional.org.
They were written by `jurisdictional --save responses`.
`index.json` names the method, path, query, status, and file for each one.
The file is the response body, unchanged aside from pretty-printed JSON.
Another app can read the index and then open the file.

The example place is Vacaville, California.
The place id is 70118.
The city agency id is 13012.
The city council body id is 1.
One council member is person 1.

`activity` is not included.
That response is about 5 MB for a 7-day window.
`geo layers` is not included.
That response is about 2.6 MB because each layer carries GeoJSON.
`jurisdictions scene` requires a token, so it is not here.
A login response is never saved.

Run the same command with `--save` when you want a fresh local copy, including the two large reads.
