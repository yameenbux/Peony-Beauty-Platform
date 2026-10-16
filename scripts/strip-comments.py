#!/usr/bin/env python3
"""Take the comments out of the shipped copy, not out of the source.

This codebase explains itself in comments and that is worth keeping - but it
is worth keeping for whoever reads the repository, not for every browser that
opens the dashboard. 14 KB of the 183 KB dashboard is comments.

Only two kinds are removed, both unambiguous:

  * HTML comments. Run AFTER set-analytics-notice.py, which uses
    <!--ANALYTICS:ON--> markers to decide which paragraph ships; by the time
    this runs those have done their job.
  * CSS comments, inside <style> blocks only. CSS has no string escape that
    can contain an unbalanced /* and no line comments, so the match is exact.

JavaScript comments are deliberately left alone. Stripping those safely needs
a parser: a string or a regex literal can contain // or /*, and a minifier
that gets it wrong breaks the page silently. 14 KB is not worth that.
"""
import re
import sys

STYLE = re.compile(r"(<style[^>]*>)(.*?)(</style>)", re.S)
CSS_COMMENT = re.compile(r"/\*.*?\*/", re.S)
HTML_COMMENT = re.compile(r"<!--.*?-->", re.S)


def strip(text: str) -> str:
    # <style> first, so the HTML pass cannot reach inside one
    def css(m):
        return m.group(1) + CSS_COMMENT.sub("", m.group(2)) + m.group(3)

    text = STYLE.sub(css, text)
    # A conditional comment would change rendering; nothing here uses one, and
    # leaving them would be the safe failure, so they are kept deliberately.
    text = HTML_COMMENT.sub(
        lambda m: m.group(0) if m.group(0).startswith("<!--[if") else "", text)
    # collapse the blank lines the removals leave behind
    return re.sub(r"\n[ \t]*\n(?:[ \t]*\n)+", "\n\n", text)


def main(paths):
    saved = 0
    for p in paths:
        with open(p, encoding="utf-8") as fh:
            before = fh.read()
        after = strip(before)
        if after != before:
            with open(p, "w", encoding="utf-8") as fh:
                fh.write(after)
        saved += len(before) - len(after)
    print(f"  comments: {saved / 1024:.1f} KB removed from the shipped copy")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
