"""Keeps whichever half of the privacy notice is true of this build.

The notice carries two versions of every passage that depends on whether
visitors are being counted, each wrapped in a marker. The build deletes the one
that does not apply, so the page that ships states one fact rather than
describing a setting. Doing this in the browser instead would mean a legal
notice whose claims arrive after the text does, and that a reader with script
disabled would see twice over.

    python3 scripts/set-analytics-notice.py dist/privacy.html on
    python3 scripts/set-analytics-notice.py dist/privacy.html        # off
"""
import re
import sys

path = sys.argv[1]
on = len(sys.argv) > 2 and sys.argv[2] == "on"
keep, drop = ("ON", "OFF") if on else ("OFF", "ON")

s = open(path, encoding="utf-8").read()

dropped = re.subn(
    r"[ \t]*<!--ANALYTICS:%s-->.*?<!--/ANALYTICS:%s-->\n?" % (drop, drop),
    "", s, flags=re.S)
s, n_drop = dropped
if n_drop == 0:
    sys.exit("%s: no ANALYTICS:%s block to remove - has the notice changed?"
             % (path, drop))

# The two sets need not be the same size - "Counting visits" is a section that
# only exists in one of them - so each is only required to pair up with itself.
s, n_keep = re.subn(r"[ \t]*<!--/?ANALYTICS:%s-->\n?" % keep, "", s)
if n_keep % 2:
    sys.exit("%s: %d ANALYTICS:%s markers, which cannot pair up"
             % (path, n_keep, keep))
if "ANALYTICS" in s:
    sys.exit("%s: a marker survived - the blocks are not nested the way this "
             "expects" % path)

open(path, "w", encoding="utf-8").write(s)
print("  privacy notice: the %s wording kept, %d passage(s)"
      % (keep.lower(), n_drop))
