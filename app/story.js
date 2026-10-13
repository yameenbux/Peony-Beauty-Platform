/* Booked In — the card she posts to her Stories.
 *
 * Her booking page is a link, and a link in a bio is passive: it works only
 * for somebody who has already decided to go looking. What actually fills a
 * quiet Thursday is a picture in a Story saying Thursday is quiet. This draws
 * that picture from her real diary, in one tap, so it takes less effort than
 * typing the times out by hand - which is the only reason anybody will do it
 * every week.
 *
 * DRAWN IN HER BROWSER, on a canvas, never on a server. Partly because there
 * is no server to draw it on - everything here is a static file and a database
 * - and partly because it means her diary does not have to be sent anywhere to
 * become a picture of itself. The bytes exist for as long as the tab is open.
 *
 * 1080x1920 is the Stories frame. Instagram, TikTok and Facebook all put their
 * own buttons over roughly the top and bottom 250px of it, so everything that
 * has to be readable lives inside SAFE below. A card whose times are hidden
 * behind a "Send message" bar is worse than no card.
 */
(function (global) {
  "use strict";

  var W = 1080, H = 1920;
  var SAFE = { top: 270, bottom: 1650 };   /* what the apps do not cover */

  var INK        = "#2A1119";
  var PLUM       = "#43192A";
  var INK_SOFT   = "#6B4753";
  var CARMINE    = "#B8465C";
  var BLUSH      = "#F2D7DB";
  var BLUSH_DEEP = "#E5B9C0";
  var PORCELAIN  = "#FDFAFA";
  var WHITE      = "#FFFFFF";

  var SERIF = '"Bodoni Moda", Georgia, serif';
  var SANS  = '"Plus Jakarta Sans", system-ui, -apple-system, sans-serif';

  /* Canvas will silently fall back to a default face if the font has not been
     loaded yet, and the card comes out in Times with no warning. Every size
     and weight actually used has to be asked for first. */
  function fonts() {
    if (!global.document || !document.fonts) return Promise.resolve();
    return Promise.all([
      '400 120px ' + SERIF, '500 64px ' + SERIF, '400 44px ' + SERIF,
      '700 34px ' + SANS,   '600 40px ' + SANS,  '400 36px ' + SANS,
      '700 30px ' + SANS
    ].map(function (f) { return document.fonts.load(f); }))
     .then(function () { return document.fonts.ready; });
  }

  /* ----------------------------------------------------------- drawing -- */

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y,     x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x,     y + h, r);
    ctx.arcTo(x,     y + h, x,     y,     r);
    ctx.arcTo(x,     y,     x + w, y,     r);
    ctx.closePath();
  }

  /* Canvas gained letterSpacing late and Safari was last. Without it the caps
     labels set solid and look like a mistake, so they are drawn a glyph at a
     time instead - slow, and irrelevant for twenty characters. */
  function tracked(ctx, text, x, y, px) {
    if ("letterSpacing" in ctx) {
      ctx.letterSpacing = px + "px";
      ctx.fillText(text, x, y);
      ctx.letterSpacing = "0px";
      return;
    }
    var cx = x;
    for (var i = 0; i < text.length; i++) {
      ctx.fillText(text[i], cx, y);
      cx += ctx.measureText(text[i]).width + px;
    }
  }
  function trackedWidth(ctx, text, px) {
    return ctx.measureText(text).width + px * Math.max(text.length - 1, 0);
  }

  /* A headline sized to fit rather than set at a fixed size and hoped for.
     "Thursday 22 October" at 120px is wider than the card, and a card whose
     own date runs off the edge is worse than no card at all. Shrinks first,
     wraps second, and gives up at minPx rather than becoming unreadable. */
  function headline(ctx, text, font, maxW, maxLines, startPx, minPx) {
    var px = startPx, lines;
    for (;;) {
      ctx.font = font.replace("%", px);
      lines = wrap(ctx, text, maxW);
      if (lines.length <= maxLines || px <= minPx) break;
      px -= 6;
    }
    /* Still too wide on one line even at the floor: let it wrap as far as it
       needs to. Three short lines beat one clipped one. */
    if (lines.some(function (L) { return ctx.measureText(L).width > maxW; })) {
      ctx.font = font.replace("%", minPx);
      px = minPx;
      lines = wrap(ctx, text, maxW);
    }
    return { lines: lines, px: px, lineH: Math.round(px * 1.1) };
  }

  /* One line that must not grow: shrink to a floor, then cut. Used for the
     things whose length is somebody else's decision - a studio name, a
     treatment name - where wrapping would break the layout around them. */
  function fitLine(ctx, text, font, maxW, startPx, minPx, track) {
    track = track || 0;
    var px = startPx;
    for (;;) {
      ctx.font = font.replace("%", px);
      if (trackedWidth(ctx, text, track) <= maxW || px <= minPx) break;
      px -= 2;
    }
    if (trackedWidth(ctx, text, track) <= maxW) return { text: text, px: px };
    var cut = text;
    while (cut.length > 1 &&
           trackedWidth(ctx, cut + "\u2026", track) > maxW) cut = cut.slice(0, -1);
    return { text: cut.replace(/[\s,]+$/, "") + "\u2026", px: px };
  }

  /* Blocks are measured before any of them is drawn, so the whole stack can be
     centred in the space between the top of the safe area and the footer.
     Anchoring to the top instead leaves a card with three free slots looking
     like a card that lost two of them. */
  function layout(blocks, topY, bottomY) {
    var total = blocks.reduce(function (a, b) { return a + b.h + (b.gap || 0); }, 0);
    var y = topY + Math.max(0, (bottomY - topY - total) / 2);
    blocks.forEach(function (b) { b.draw(y); y += b.h + (b.gap || 0); });
  }

  /* Greedy wrap. Returns the lines rather than drawing them, because the
     caller needs the height before it can decide where the block starts. */
  function wrap(ctx, text, maxW) {
    var words = String(text).split(/\s+/), lines = [], line = "";
    for (var i = 0; i < words.length; i++) {
      var next = line ? line + " " + words[i] : words[i];
      if (ctx.measureText(next).width > maxW && line) { lines.push(line); line = words[i]; }
      else line = next;
    }
    if (line) lines.push(line);
    return lines;
  }

  /* The mark, same construction as site/icon.svg: six slots, one taken. A
     round cap adds half the stroke at each end of a dash, so the dash is the
     period less the gap you want to see and the stroke. */
  function ring(ctx, cx, cy, r, stroke, visualGap, pale, strong) {
    var period = (2 * Math.PI * r) / 6;
    var dash = period - (visualGap + stroke);
    ctx.save();
    ctx.translate(cx, cy);
    ctx.rotate(-Math.PI / 2);
    ctx.lineCap = "round";
    ctx.lineWidth = stroke;

    ctx.strokeStyle = pale;
    ctx.setLineDash([dash, period - dash]);
    ctx.beginPath(); ctx.arc(0, 0, r, 0, 2 * Math.PI); ctx.stroke();

    ctx.strokeStyle = strong;
    ctx.setLineDash([dash, 2 * Math.PI * r - dash]);
    ctx.lineDashOffset = -2 * period;
    ctx.beginPath(); ctx.arc(0, 0, r, 0, 2 * Math.PI); ctx.stroke();
    ctx.restore();
  }

  function background(ctx) {
    ctx.fillStyle = PORCELAIN;
    ctx.fillRect(0, 0, W, H);

    /* The bloom, as on the marketing page and the share cards. Placed behind
       the headline rather than over it: it is the warmth, not the subject. */
    var g = ctx.createRadialGradient(W * 0.86, 230, 0, W * 0.86, 230, 760);
    g.addColorStop(0, "rgba(242,215,219,1)");
    g.addColorStop(0.46, "rgba(250,239,240,1)");
    g.addColorStop(1, "rgba(253,250,250,0)");
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, 1100);

    /* The mark, oversized and cropped by the corner. */
    ring(ctx, W + 60, H - 180, 300, 62, 46, BLUSH, BLUSH_DEEP);
  }

  /* A block rather than something pinned to the top of the card: her name
     belongs immediately above the headline, and pinning it left it stranded
     three hundred pixels clear of the thing it introduces. */
  function eyebrowBlock(ctx, text) {
    /* Her studio name is whatever she typed. "The Lash & Brow Studio by
       Antoinette, Nuneaton" in tracked caps is wider than the card. */
    var f = fitLine(ctx, String(text).toUpperCase(), "700 %px " + SANS, 888, 30, 20, 6);
    return { h: 40, gap: 36, draw: function (y) {
      ctx.font = "700 " + f.px + "px " + SANS;
      ctx.fillStyle = CARMINE;
      ctx.textAlign = "left";
      tracked(ctx, f.text, 96, y + 30, 6);
    }};
  }

  /* The link, in a pill, at the bottom where a thumb is already hovering. */
  function footer(ctx, link, credit) {
    /* The pill sits at the bottom of what stays visible, and the credit goes
       ABOVE it. Below, which is where it was, is underneath the app's own
       "Send message" bar on every phone it would ever be seen on. */
    var y = SAFE.bottom - 108;
    ctx.font = "600 40px " + SANS;
    var w = ctx.measureText(link).width + 96;
    ctx.fillStyle = CARMINE;
    roundRect(ctx, 96, y, w, 96, 48);
    ctx.fill();
    ctx.fillStyle = WHITE;
    ctx.textAlign = "left";
    ctx.textBaseline = "middle";
    ctx.fillText(link, 96 + 48, y + 50);
    ctx.textBaseline = "alphabetic";

    if (credit) {
      /* Free carries the mark, Pro does not - the same rule as the credit line
         on her page, and the reason the free tier can pay for itself. */
      ctx.font = "400 26px " + SANS;
      ctx.fillStyle = "rgba(107,71,83,.72)";
      ctx.fillText("Booked In", 96, y - 36);
      ring(ctx, 96 + ctx.measureText("Booked In").width + 34, y - 44, 15, 5, 3.6,
           BLUSH_DEEP, CARMINE);
    }
  }

  /* --------------------------------------------------------- the cards -- */

  var SERIF_H = "400 %px " + SERIF;
  var BODY_BOT = SAFE.bottom - 260;      /* above the credit and the pill */

  function cardSpaces(ctx, d) {
    background(ctx);

    var h = headline(ctx, d.slots.length === 1 ? "One space left this week"
                                               : "Spaces this week",
                     SERIF_H, 888, 3, 120, 76);
    var blocks = [eyebrowBlock(ctx, d.studio), {
      h: h.lines.length * h.lineH, gap: 56,
      draw: function (y) {
        ctx.font = SERIF_H.replace("%", h.px);
        ctx.fillStyle = PLUM; ctx.textAlign = "left";
        h.lines.forEach(function (L, i) { ctx.fillText(L, 96, y + (i + 1) * h.lineH - 20); });
      }
    }];

    d.slots.slice(0, 5).forEach(function (s) {
      /* The time is the point of the row and keeps its size; the day takes
         whatever is left. "Wednesday 28 September" at full size runs past the
         end of the pill and out of the card. */
      ctx.font = "700 46px " + SANS;
      var tw = ctx.measureText(s.time).width;
      var day = fitLine(ctx, s.day, "600 %px " + SANS, 888 - 44 - 44 - tw - 24, 44, 30);
      blocks.push({ h: 112, gap: 24, draw: function (y) {
        ctx.fillStyle = BLUSH;
        roundRect(ctx, 96, y, 888, 112, 24);
        ctx.fill();
        ctx.font = "600 " + day.px + "px " + SANS;
        ctx.fillStyle = PLUM; ctx.textAlign = "left";
        ctx.fillText(day.text, 140, y + 72);
        ctx.font = "700 46px " + SANS;
        ctx.fillStyle = CARMINE; ctx.textAlign = "right";
        ctx.fillText(s.time, 940, y + 72);
        ctx.textAlign = "left";
      }});
    });

    if (d.service) {
      blocks.push({ h: 50, gap: 0, draw: function (y) {
        ctx.font = "400 36px " + SANS;
        ctx.fillStyle = INK_SOFT; ctx.textAlign = "left";
        ctx.fillText(d.service + (d.price ? " \u00b7 " + d.price : ""), 96, y + 40);
      }});
    }
    layout(blocks, SAFE.top, BODY_BOT);
    footer(ctx, d.link, d.credit);
  }

  function cardGap(ctx, d) {
    background(ctx);

    var s = d.slots[0];
    var day  = headline(ctx, s.day,  SERIF_H, 888, 2, 120, 64);
    var time = headline(ctx, s.time, SERIF_H, 888, 1, 120, 72);
    var blocks = [
      eyebrowBlock(ctx, d.studio),
      { h: day.lines.length * day.lineH, gap: 0, draw: function (y) {
          ctx.font = SERIF_H.replace("%", day.px);
          ctx.fillStyle = PLUM; ctx.textAlign = "left";
          day.lines.forEach(function (L, i) { ctx.fillText(L, 96, y + (i + 1) * day.lineH - 20); });
        } },
      { h: time.lineH, gap: 56, draw: function (y) {
          ctx.font = SERIF_H.replace("%", time.px);
          ctx.fillStyle = CARMINE; ctx.textAlign = "left";
          ctx.fillText(time.lines[0], 96, y + time.lineH - 20);
        } }
    ];

    ctx.font = "400 44px " + SERIF;
    /* The treatment keeps its own capitals. Lowercasing it to fit the sentence
       turns "Russian infills" into "russian infills", which looks like a typo
       on a card she is about to put her name to. */
    var sub = wrap(ctx, d.service ? "just came free for " + d.service : "just came free", 888);
    blocks.push({ h: sub.length * 62, gap: d.price ? 44 : 0, draw: function (y) {
      ctx.font = "400 44px " + SERIF;
      ctx.fillStyle = INK; ctx.textAlign = "left";
      sub.forEach(function (L, i) { ctx.fillText(L, 96, y + (i + 1) * 62 - 16); });
    }});

    if (d.price) {
      blocks.push({ h: 52, gap: 0, draw: function (y) {
        ctx.font = "700 44px " + SANS;
        ctx.fillStyle = INK_SOFT; ctx.textAlign = "left";
        ctx.fillText(d.price, 96, y + 44);
      }});
    }
    layout(blocks, SAFE.top, BODY_BOT);
    footer(ctx, d.link, d.credit);
  }

  function cardBook(ctx, d) {
    background(ctx);

    var name = headline(ctx, d.studio, SERIF_H, 888, 3, 120, 68);
    var blocks = [
      { h: 116, gap: 40, draw: function (y) {
          ring(ctx, 96 + 46, y + 46, 46, 15, 11, BLUSH_DEEP, CARMINE);
        } },
      { h: name.lines.length * name.lineH, gap: d.tagline ? 30 : 76,
        draw: function (y) {
          ctx.font = SERIF_H.replace("%", name.px);
          ctx.fillStyle = PLUM; ctx.textAlign = "left";
          name.lines.forEach(function (L, i) { ctx.fillText(L, 96, y + (i + 1) * name.lineH - 20); });
        } }
    ];

    if (d.tagline) {
      ctx.font = "400 44px " + SERIF;
      var tag = wrap(ctx, d.tagline, 888);
      blocks.push({ h: tag.length * 62, gap: 76, draw: function (y) {
        ctx.font = "400 44px " + SERIF;
        ctx.fillStyle = INK_SOFT; ctx.textAlign = "left";
        tag.forEach(function (L, i) { ctx.fillText(L, 96, y + (i + 1) * 62 - 16); });
      }});
    }

    (d.treatments || []).slice(0, 5).forEach(function (t) {
      ctx.font = "700 40px " + SANS;
      var pw = ctx.measureText(t.price).width;
      var nm = fitLine(ctx, t.name, "400 %px " + SANS, 888 - pw - 40, 40, 28);
      blocks.push({ h: 96, gap: 0, draw: function (y) {
        ctx.font = "400 " + nm.px + "px " + SANS;
        ctx.fillStyle = INK; ctx.textAlign = "left";
        ctx.fillText(nm.text, 96, y + 52);
        ctx.font = "700 40px " + SANS;
        ctx.fillStyle = CARMINE; ctx.textAlign = "right";
        ctx.fillText(t.price, 984, y + 52);
        ctx.textAlign = "left";
        ctx.strokeStyle = "rgba(223,194,200,.8)";
        ctx.lineWidth = 2; ctx.setLineDash([]);
        ctx.beginPath(); ctx.moveTo(96, y + 86); ctx.lineTo(984, y + 86); ctx.stroke();
      }});
    });

    blocks.push({ h: 56, gap: 0, draw: function (y) {
      ctx.font = "400 36px " + SANS;
      ctx.fillStyle = INK_SOFT; ctx.textAlign = "left";
      ctx.fillText("Book yourself in, any time of day", 96, y + 48);
    }});

    layout(blocks, SAFE.top, BODY_BOT);
    footer(ctx, d.link, d.credit);
  }

  var CARDS = { spaces: cardSpaces, gap: cardGap, book: cardBook };

  /* ------------------------------------------------------------- public -- */

  /* Returns the canvas rather than a blob, so the caller can both show it and
     decide later whether it is being downloaded or shared. */
  function render(kind, data) {
    var draw = CARDS[kind];
    if (!draw) return Promise.reject(new Error("unknown card: " + kind));
    return fonts().then(function () {
      var c = (global.document || document).createElement("canvas");
      c.width = W; c.height = H;
      var ctx = c.getContext("2d");
      ctx.textBaseline = "alphabetic";
      draw(ctx, data);
      return c;
    });
  }

  function toBlob(canvas) {
    return new Promise(function (resolve) {
      /* PNG: the card is flat colour and type, which JPEG would fringe. */
      canvas.toBlob(function (b) { resolve(b); }, "image/png");
    });
  }

  global.BookedInStory = { render: render, toBlob: toBlob, W: W, H: H, SAFE: SAFE };
})(typeof window !== "undefined" ? window : globalThis);
