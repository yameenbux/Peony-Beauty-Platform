# vendor/

Third-party code served from our own origin instead of somebody else's CDN.

## Why

Every booking page used to pull `supabase-js` from `cdn.jsdelivr.net`. Two
things were wrong with that.

The first is privacy, and it is the one that made this worth doing. A client
opening a studio's booking page was telling jsDelivr that she had opened it —
her IP address, the page, the time — and the privacy notice says nobody outside
a short list of named companies hears anything. That was not true while this
file came from somewhere else. The typefaces moved for the same reason.

The second is control. A CDN serving a modified copy of this file would own
every booking page on the platform: it has the Supabase client, so it has every
name, email and phone number typed into one. Pinning a version does not help if
the host is the thing that is wrong. Served from here, the file can only change
when this repository changes.

It costs about 108 KB on a page that was downloading the same 108 KB anyway,
from further away and over a connection it had to open first.

## What is here

| File | Version | Source |
|------|---------|--------|
| `supabase-js-2.45.4.js` | 2.45.4 | `npm pack @supabase/supabase-js@2.45.4`, `dist/umd/supabase.js` |
| `591.supabase.js` | 2.45.4 | the same tarball, `dist/umd/591.supabase.js` |

SHA-256 of the main bundle: `8596965fe918e656600a1b568d3a168f5c0d3d22a600886bb6f44a6555db01e7`

`591.supabase.js` is 223 bytes and is very likely never requested, but webpack
works out where to look for it from the URL of the main bundle, so it has to be
able to sit beside it rather than 404.

The tarball is the authoritative artefact — jsDelivr mirrors npm, so this is
the same file that used to be fetched, from the registry that publishes it.

## Updating

```
npm pack @supabase/supabase-js@<version>
tar xzf supabase-supabase-js-<version>.tgz
cp package/dist/umd/supabase.js vendor/supabase-js-<version>.js
sha256sum vendor/supabase-js-<version>.js
```

Then update the `<script src>` in `app/index.html`, `book/index.html` and
`book/manage.html`, the copy in `build.sh`, and the table above. There is a
test that fails if the pages and the file ever disagree.
