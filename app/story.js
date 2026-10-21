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

  var CARMINE_DEFAULT = "#B8465C";
  var WHITE = "#FFFFFF";

  /* ------------------------------------------------------- her palette --
     The card goes out under her name, beside her own photographs, so the one
     thing it must not look like is somebody else's software. She gives a
     colour; everything else is derived from it, because asking a lash
     technician for five hex values is asking her to do a job she did not sign
     up for and the result would clash anyway.

     The derivation is in HSL: the same hue, taken pale for the fills and dark
     for the type. That holds together for any colour she picks, including the
     black-and-gold and the sage-green that half this trade uses. */
  function hexToRgb(hex) {
    var h = String(hex || "").replace("#", "");
    if (h.length !== 6) return null;
    return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)];
  }
  function rgbToHsl(r, g, b) {
    r /= 255; g /= 255; b /= 255;
    var mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn;
    var l = (mx + mn) / 2, h = 0, s = 0;
    if (d) {
      s = d / (1 - Math.abs(2 * l - 1));
      h = mx === r ? ((g - b) / d) % 6 : mx === g ? (b - r) / d + 2 : (r - g) / d + 4;
      h *= 60; if (h < 0) h += 360;
    }
    return [h, s, l];
  }
  function hsl(h, s, l) {
    return "hsl(" + h.toFixed(1) + " " + Math.round(s * 100) + "% " + Math.round(l * 100) + "%)";
  }
  /* Relative luminance, for deciding what can be read on top of her colour. */
  function lum(rgb) {
    var c = rgb.map(function (v) {
      v /= 255; return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  }

  /* `trade` is 028's per-trade accent. Her own brand_hex still wins; without
     one the card now opens in her trade's colour instead of ours, so a
     barber's card is oxblood before he has chosen anything. */
  function palette(brandHex, theme, trade) {
    var rgb = hexToRgb(brandHex) || hexToRgb(trade) || hexToRgb(CARMINE_DEFAULT);
    var c = rgbToHsl(rgb[0], rgb[1], rgb[2]);
    var h = c[0], sat = Math.max(c[1], 0.12);
    var dark = theme === "dark";

    /* On a dark card the accent has to lift off her colour, not sink into it.
       A near-black brand would make a near-black accent invisible, so the
       lightness is pinned rather than taken from what she chose. */
    var onDark = {
      bg:     hsl(h, Math.min(sat, 0.5), 0.14),
      panel:  hsl(h, Math.min(sat, 0.45), 0.22),
      ink:    hsl(h, 0.12, 0.96),
      inkSoft:hsl(h, 0.10, 0.78),
      accent: hsl(h, Math.max(sat, 0.5), 0.72),
      pill:   hsl(h, Math.max(sat, 0.55), 0.62),
      pillInk:hsl(h, 0.3, 0.10)
    };
    var onLight = {
      bg:     hsl(h, Math.min(sat, 0.5), 0.985),
      panel:  hsl(h, Math.min(sat, 0.55), 0.90),
      ink:    hsl(h, Math.min(sat, 0.5), 0.18),
      inkSoft:hsl(h, Math.min(sat, 0.3), 0.37),
      accent: brandHex || CARMINE_DEFAULT,
      pill:   brandHex || CARMINE_DEFAULT,
      pillInk:lum(rgb) > 0.45 ? hsl(h, 0.4, 0.14) : WHITE,
      bloomA: hsl(h, Math.min(sat, 0.6), 0.90),
      bloomB: hsl(h, Math.min(sat, 0.5), 0.96)
    };
    var p = dark ? onDark : onLight;
    p.bloomA = p.bloomA || hsl(h, Math.min(sat, 0.5), 0.26);
    p.bloomB = p.bloomB || hsl(h, Math.min(sat, 0.4), 0.18);
    p.ringPale   = dark ? hsl(h, 0.3, 0.26) : hsl(h, Math.min(sat, 0.5), 0.90);
    p.ringStrong = dark ? hsl(h, 0.4, 0.40) : hsl(h, Math.min(sat, 0.5), 0.82);
    p.dark = dark;
    return p;
  }

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

  /* Left or centred. Everything on the card is placed through these two so a
     single setting moves the lot, rather than forty literal 96s. */
  function ax(p) { return p.centre ? W / 2 : 96; }
  function align(ctx, p) { ctx.textAlign = p.centre ? "center" : "left"; }

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

  function background(ctx, p) {
    ctx.fillStyle = p.bg;
    ctx.fillRect(0, 0, W, H);

    /* The bloom. Placed behind the headline rather than over it: it is the
       warmth, not the subject. Drawn with a transparent outer stop so it
       dissolves into whatever she chose rather than ending on a hard edge. */
    var g = ctx.createRadialGradient(W * 0.86, 230, 0, W * 0.86, 230, 760);
    g.addColorStop(0, p.bloomA);
    g.addColorStop(0.46, p.bloomB);
    g.addColorStop(1, "rgba(0,0,0,0)");
    ctx.save();
    ctx.globalAlpha = p.dark ? 0.75 : 1;
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, 1100);
    ctx.restore();

    /* The mark, oversized and cropped by the corner. */
    ring(ctx, W + 60, H - 180, 300, 62, 46, p.ringPale, p.ringStrong);
  }

  /* Her logo, if she has one. Resolved to null rather than thrown on failure:
     a card that will not draw because a picture 404ed is worse than a card
     without the picture. crossOrigin matters - without it the canvas is
     tainted the moment the logo lands and toBlob throws, so she would get a
     perfect preview and nothing to post. */
  function loadLogo(url) {
    if (!url || !global.Image) return Promise.resolve(null);
    return new Promise(function (resolve) {
      var img = new Image();
      img.crossOrigin = "anonymous";
      img.onload = function () { resolve(img); };
      img.onerror = function () { resolve(null); };
      img.src = url;
      setTimeout(function () { resolve(null); }, 6000);   /* never hang the card */
    });
  }

  /* Her logo where our ring would be, or her name in tracked caps if she has
     no logo. A block rather than something pinned to the top of the card: it
     belongs immediately above the headline, and pinning it left it stranded
     three hundred pixels clear of the thing it introduces. */
  function markBlock(ctx, p, text, logo) {
    if (logo) {
      /* Contained in a 150-high box at whatever aspect it came in at, so a
         wide wordmark and a square badge both sit on the same baseline. */
      var h = 150, w = Math.min(logo.width * (h / logo.height), 560);
      if (w === 560) h = logo.height * (560 / logo.width);
      return { h: h, gap: 44, draw: function (y) {
        ctx.drawImage(logo, p.centre ? (W - w) / 2 : 96, y, w, h);
      }};
    }
    var f = fitLine(ctx, String(text).toUpperCase(), "700 %px " + SANS, 888, 30, 20, 6);
    return { h: 40, gap: 36, draw: function (y) {
      ctx.font = "700 " + f.px + "px " + SANS;
      ctx.fillStyle = p.accent;
      ctx.textAlign = "left";
      var x = p.centre ? (W - trackedWidth(ctx, f.text, 6)) / 2 : 96;
      tracked(ctx, f.text, x, y + 30, 6);
    }};
  }

  /* The link, in a pill, at the bottom where a thumb is already hovering. */
  function footer(ctx, p, link) {
    var y = SAFE.bottom - 108;
    ctx.font = "600 40px " + SANS;
    var w = ctx.measureText(link).width + 96;
    var x = p.centre ? (W - w) / 2 : 96;
    ctx.fillStyle = p.pill;
    roundRect(ctx, x, y, w, 96, 48);
    ctx.fill();
    ctx.fillStyle = p.pillInk;
    ctx.textAlign = "left";
    ctx.textBaseline = "middle";
    ctx.fillText(link, x + 48, y + 50);
    ctx.textBaseline = "alphabetic";

    /* The mark used to sit here on free cards and come off on Pro. It is gone
       for everybody. This is a post she makes to her own followers under her
       own name, so a watermark on it is a watermark on her - and 013 already
       observed that a card looking like us rather than like her is a card she
       will not post, which costs us the reach the mark was there to buy.
       "Powered by Booked In" stays in the booking page's footer on every plan.
       That page is ours as well as hers; this one is only hers. */
  }

  var SERIF_H = "400 %px " + SERIF;
  var BODY_BOT = SAFE.bottom - 260;      /* above the pill */

  function cardSpaces(ctx, p, d) {
    background(ctx, p);
    var h = headline(ctx, d.slots.length === 1 ? "One space left this week"
                                               : "Spaces this week",
                     SERIF_H, 888, 3, 120, 76);
    var blocks = [markBlock(ctx, p, d.studio, d.logo), {
      h: h.lines.length * h.lineH, gap: 56,
      draw: function (y) {
        ctx.font = SERIF_H.replace("%", h.px);
        ctx.fillStyle = p.ink; align(ctx, p);
        h.lines.forEach(function (L, i) { ctx.fillText(L, ax(p), y + (i + 1) * h.lineH - 20); });
      }
    }];

    d.slots.slice(0, 5).forEach(function (sl) {
      ctx.font = "700 46px " + SANS;
      var tw = ctx.measureText(sl.time).width;
      var day = fitLine(ctx, sl.day, "600 %px " + SANS, 888 - 44 - 44 - tw - 24, 44, 30);
      blocks.push({ h: 112, gap: 24, draw: function (y) {
        ctx.fillStyle = p.panel;
        roundRect(ctx, 96, y, 888, 112, 24);
        ctx.fill();
        ctx.font = "600 " + day.px + "px " + SANS;
        ctx.fillStyle = p.ink; ctx.textAlign = "left";
        ctx.fillText(day.text, 140, y + 72);
        ctx.font = "700 46px " + SANS;
        ctx.fillStyle = p.accent; ctx.textAlign = "right";
        ctx.fillText(sl.time, 940, y + 72);
        ctx.textAlign = "left";
      }});
    });

    if (d.service) {
      blocks.push({ h: 50, gap: 0, draw: function (y) {
        ctx.font = "400 36px " + SANS;
        ctx.fillStyle = p.inkSoft; align(ctx, p);
        ctx.fillText(d.service + (d.price ? " \u00b7 " + d.price : ""), ax(p), y + 40);
      }});
    }
    layout(blocks, SAFE.top, BODY_BOT);
    footer(ctx, p, d.link);
  }

  function cardGap(ctx, p, d) {
    background(ctx, p);
    var sl = d.slots[0];
    var day  = headline(ctx, sl.day,  SERIF_H, 888, 2, 120, 64);
    var time = headline(ctx, sl.time, SERIF_H, 888, 1, 120, 72);
    var blocks = [
      markBlock(ctx, p, d.studio, d.logo),
      { h: day.lines.length * day.lineH, gap: 0, draw: function (y) {
          ctx.font = SERIF_H.replace("%", day.px);
          ctx.fillStyle = p.ink; align(ctx, p);
          day.lines.forEach(function (L, i) { ctx.fillText(L, ax(p), y + (i + 1) * day.lineH - 20); });
        } },
      { h: time.lineH, gap: 56, draw: function (y) {
          ctx.font = SERIF_H.replace("%", time.px);
          ctx.fillStyle = p.accent; align(ctx, p);
          ctx.fillText(time.lines[0], ax(p), y + time.lineH - 20);
        } }
    ];

    ctx.font = "400 44px " + SERIF;
    /* The treatment keeps its own capitals. Lowercasing it to fit the sentence
       turns "Russian infills" into "russian infills", which looks like a typo
       on a card she is about to put her name to. */
    var sub = wrap(ctx, d.service ? "just came free for " + d.service : "just came free", 888);
    blocks.push({ h: sub.length * 62, gap: d.price ? 44 : 0, draw: function (y) {
      ctx.font = "400 44px " + SERIF;
      ctx.fillStyle = p.ink; align(ctx, p);
      sub.forEach(function (L, i) { ctx.fillText(L, ax(p), y + (i + 1) * 62 - 16); });
    }});

    if (d.price) {
      blocks.push({ h: 52, gap: 0, draw: function (y) {
        ctx.font = "700 44px " + SANS;
        ctx.fillStyle = p.inkSoft; align(ctx, p);
        ctx.fillText(d.price, ax(p), y + 44);
      }});
    }
    layout(blocks, SAFE.top, BODY_BOT);
    footer(ctx, p, d.link);
  }

  function cardBook(ctx, p, d) {
    background(ctx, p);
    var name = headline(ctx, d.studio, SERIF_H, 888, 3, 120, 68);
    var blocks = [
      d.logo
        ? markBlock(ctx, p, d.studio, d.logo)
        : { h: 116, gap: 40, draw: function (y) {
              ring(ctx, (p.centre ? W / 2 : 96 + 46), y + 46, 46, 15, 11,
                   p.ringPale, p.accent);
            } },
      { h: name.lines.length * name.lineH, gap: d.tagline ? 30 : 76,
        draw: function (y) {
          ctx.font = SERIF_H.replace("%", name.px);
          ctx.fillStyle = p.ink; align(ctx, p);
          name.lines.forEach(function (L, i) { ctx.fillText(L, ax(p), y + (i + 1) * name.lineH - 20); });
        } }
    ];

    if (d.tagline) {
      ctx.font = "400 44px " + SERIF;
      var tag = wrap(ctx, d.tagline, 888);
      blocks.push({ h: tag.length * 62, gap: 76, draw: function (y) {
        ctx.font = "400 44px " + SERIF;
        ctx.fillStyle = p.inkSoft; align(ctx, p);
        tag.forEach(function (L, i) { ctx.fillText(L, ax(p), y + (i + 1) * 62 - 16); });
      }});
    }

    (d.treatments || []).slice(0, 5).forEach(function (t) {
      ctx.font = "700 40px " + SANS;
      var pw = ctx.measureText(t.price).width;
      var nm = fitLine(ctx, t.name, "400 %px " + SANS, 888 - pw - 40, 40, 28);
      blocks.push({ h: 96, gap: 0, draw: function (y) {
        ctx.font = "400 " + nm.px + "px " + SANS;
        ctx.fillStyle = p.ink; ctx.textAlign = "left";
        ctx.fillText(nm.text, 96, y + 52);
        ctx.font = "700 40px " + SANS;
        ctx.fillStyle = p.accent; ctx.textAlign = "right";
        ctx.fillText(t.price, 984, y + 52);
        ctx.textAlign = "left";
        ctx.strokeStyle = p.panel;
        ctx.lineWidth = 2; ctx.setLineDash([]);
        ctx.beginPath(); ctx.moveTo(96, y + 86); ctx.lineTo(984, y + 86); ctx.stroke();
      }});
    });

    blocks.push({ h: 56, gap: 0, draw: function (y) {
      ctx.font = "400 36px " + SANS;
      ctx.fillStyle = p.inkSoft; align(ctx, p);
      ctx.fillText("Book yourself in, any time of day", ax(p), y + 48);
    }});

    layout(blocks, SAFE.top, BODY_BOT);
    footer(ctx, p, d.link);
  }

  var CARDS = { spaces: cardSpaces, gap: cardGap, book: cardBook };

  /* ------------------------------------------------------------- public -- */

  /* Returns the canvas rather than a blob, so the caller can both show it and
     decide later whether it is being downloaded or shared. */
  function render(kind, data) {
    var draw = CARDS[kind];
    if (!draw) return Promise.reject(new Error("unknown card: " + kind));
    var d = data || {};
    return Promise.all([fonts(), loadLogo(d.logo_url)]).then(function (got) {
      var p = palette(d.brand_hex, d.card_theme, d.trade_accent);
      p.centre = d.card_align === "centre";
      var c = (global.document || document).createElement("canvas");
      c.width = W; c.height = H;
      var ctx = c.getContext("2d");
      ctx.textBaseline = "alphabetic";
      var withLogo = {};
      for (var k in d) withLogo[k] = d[k];
      withLogo.logo = got[1];
      draw(ctx, p, withLogo);
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
