"""Refuses to ship a build that contains a key it should not.

Supabase issues two keys. The anon key belongs in the browser: every table is
behind row level security and the key grants nothing on its own. The
service-role key bypasses every one of those policies, so one of those pasted
into a config file and deployed hands the entire platform - every studio's
clients, names, emails, phone numbers - to anybody who views source.

The two look almost identical. Both are JWTs, both start eyJ, both are long and
unmemorable, and the only thing that distinguishes them is one word inside the
payload. So this decodes them rather than reading the surrounding text: a
comment that says the words "service role" is not a leak, and a key that says
it in its payload is, and no amount of grepping for the phrase can tell those
two apart.

    python3 scripts/check-secrets.py dist
"""
import base64
import json
import os
import re
import sys

JWT = re.compile(rb"eyJ[A-Za-z0-9_-]{8,}\.(eyJ[A-Za-z0-9_-]{8,})\.[A-Za-z0-9_-]{8,}")
# A key pasted into an assignment, even one that is not a well-formed JWT.
NAMED = re.compile(
    rb"""(service[_-]?role[_-]?key|SUPABASE_SERVICE[_A-Z]*)"""
    rb"""\s*[:=]\s*["'][^"'\s]{20,}""", re.I)
SKIP = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".woff2", ".woff", ".ttf"}


def payload(chunk):
    """The middle third of a JWT, base64url with the padding left off."""
    try:
        raw = base64.urlsafe_b64decode(chunk + b"=" * (-len(chunk) % 4))
        return json.loads(raw)
    except Exception:
        return None


def main(root):
    problems, keys = [], set()
    for dirpath, _, names in os.walk(root):
        for n in names:
            p = os.path.join(dirpath, n)
            if os.path.splitext(n)[1].lower() in SKIP:
                continue
            blob = open(p, "rb").read()

            for m in NAMED.finditer(blob):
                problems.append("%s: a service-role key is assigned here" % p)

            for m in JWT.finditer(blob):
                keys.add(m.group(0))
                body = payload(m.group(1))
                if not body:
                    continue
                role = str(body.get("role", "")) + " " + str(body.get("sub", ""))
                if "service_role" in role:
                    problems.append(
                        "%s: this key's payload says role=service_role. It bypasses "
                        "every row level security policy." % p)

    # The anon key is meant to be here. A second, different one is a question
    # worth answering before it goes to production.
    if len(keys) > 1:
        problems.append(
            "%s: %d different API keys are present, expected at most 1 (the anon key)"
            % (root, len(keys)))

    if problems:
        print("  REFUSING TO BUILD:")
        for line in problems:
            print("    " + line)
        return 1
    print("  secrets: %d API key(s) in the build, none of them privileged"
          % len(keys))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "dist"))
