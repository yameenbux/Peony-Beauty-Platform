"""Adds a Content-Security-Policy to each built page. NOT WIRED INTO build.sh.

   STATUS: written, works on the static pages, and deliberately parked.

   It was run against the whole suite. The four static-page suites pass under
   it - marketing, routing, links, speed. The app and the booking page do not:
   photo upload needed blob: in img-src (fixed here), and after that four
   assertions about checkout and the billing portal still fail, plus
   test_story's ink probe, which is addScriptTag and cannot be hashed. The
   remaining breakage was not run to ground.

   It is parked rather than finished because the failure mode is the worst one
   available: a wrong hash or a missing origin is not a warning, it is a studio
   whose photographs will not upload or whose Go Pro button does nothing, found
   by her rather than by us. A missing CSP is a weaker position than a correct
   one and a much stronger position than a broken one.

   To finish it: run the browser suites, fix what the console reports, and only
   then wire the call back into build.sh (last, after strip-comments.py).

   It also belongs in the Render header rather than here in the end, because
   frame-ancestors is ignored in a meta tag and clickjacking needs it - the
   same dashboard page as X-Frame-Options, which is already outstanding.


Render serves this site and its headers are set in a dashboard, not from
render.yaml - the live service was created through the API, so nothing in that
file reaches production. A <meta http-equiv> is therefore the only CSP this
repository can actually ship, and it is worth shipping: the booking page renders
a studio's own words and her client's name, and 025 has already had to take a
`javascript:` URI out of an href on it.

The scripts here are inline, so 'unsafe-inline' would be the easy way and would
also make the policy pointless - an injected <script> would run. Instead every
inline script is hashed, which browsers honour in place of 'unsafe-inline'.
That works here only because no page uses an inline event handler: an onclick=
cannot be hashed, and adding one would silently stop working under this policy.

Run LAST, after strip-comments.py and after the analytics beacon: both change
the bytes inside a <script>, and a hash of the wrong bytes is a blank page.

What this cannot do: frame-ancestors is ignored in a meta tag. Clickjacking
still needs X-Frame-Options or a real CSP header, set on Render.

  python3 -I scripts/add-csp.py dist
"""
import base64
import hashlib
import pathlib
import re
import sys

SCRIPT = re.compile(r"<script(?![^>]*\ssrc=)([^>]*)>(.*?)</script>", re.S | re.I)
HEAD = re.compile(r"(<meta\s+charset[^>]*>|<head[^>]*>)", re.I)


def origins(dist):
    """The hosts the pages genuinely talk to, read off the generated config."""
    cfg = dist / "platform" / "config.js"
    found = set()
    if cfg.exists():
        for m in re.finditer(r'"(https://[^"]+)"', cfg.read_text()):
            u = re.match(r"(https://[^/]+)", m.group(1))
            if u:
                found.add(u.group(1))
    return sorted(found)


def policy(hashes, api, beacon):
    script = ["'self'"] + ["'%s'" % h for h in hashes]
    if beacon:
        script.append("https://static.cloudflareinsights.com")
    connect = ["'self'"] + api
    if beacon:
        connect.append("https://cloudflareinsights.com")
    return "; ".join([
        "default-src 'self'",
        "base-uri 'self'",
        "object-src 'none'",
        "frame-src 'none'",
        # Her photographs are served from Supabase storage; data: is the 1x1
        # the tests use and the inline marks.
        # blob: because a photo she picks is previewed from an object URL
        # before it is ever uploaded, and the calendar file and the story card
        # are handed over the same way. Leaving it out does not fail on load -
        # it fails the first time she chooses a photograph.
        " ".join(["img-src 'self' data: blob:"] + api),
        "font-src 'self'",
        # Style attributes are written throughout the pages, and a style
        # cannot run code: this is the one place the policy stays loose.
        "style-src 'self' 'unsafe-inline'",
        "script-src " + " ".join(script),
        "connect-src " + " ".join(connect),
        # Nothing on this site posts anywhere but itself.
        "form-action 'self'",
    ])


def main(root):
    dist = pathlib.Path(root)
    api = origins(dist)
    done = 0
    for p in sorted(dist.rglob("*.html")):
        s = p.read_text()
        if "Content-Security-Policy" in s:
            continue
        hashes = []
        for _attrs, body in SCRIPT.findall(s):
            digest = hashlib.sha256(body.encode()).digest()
            hashes.append("sha256-" + base64.b64encode(digest).decode())
        beacon = "static.cloudflareinsights.com" in s
        tag = '<meta http-equiv="Content-Security-Policy" content="%s">' % policy(
            hashes, api, beacon)
        m = HEAD.search(s)
        if not m:
            print("  csp: SKIPPED %s (no <head>)" % p)
            continue
        p.write_text(s[:m.end()] + "\n" + tag + s[m.end():])
        done += 1
    print("  csp: %d page(s), api origins: %s" % (done, ", ".join(api) or "none"))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "dist")
