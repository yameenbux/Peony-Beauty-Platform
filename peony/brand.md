# Peony — brand

A booking platform for solo beauty professionals. The name is the flower that
appears on every mood board in this industry: it reads expensive, it is five
letters, and its layered petals give a mark that still reads at favicon size.

Client pages live at `<her-name>.peony.uk`. The free tier carries a small
"Booked with Peony" line in the footer; Pro removes it.

## Mark

`logo.svg`. One petal path rotated into two rings — eight outer, five inner —
over a champagne centre. It is built rather than drawn, so the petal count and
density can be tuned without redrawing anything.

## Colour

The palette reads the flower outward: a carmine heart, blush petals, a
porcelain edge. Champagne is the only metal and appears only on hover sweeps
and the centre of the mark.

| Token | Hex | Use |
|---|---|---|
| `--porcelain` | `#FDFAFA` | page ground |
| `--petal` | `#FAEFF0` | raised surfaces, bands |
| `--blush` | `#F2D7DB` | fills on dark |
| `--blush-deep` | `#E5B9C0` | borders on dark, eyebrows on dark |
| `--carmine` | `#B8465C` | accent, eyebrows, prices, ticks |
| `--carmine-deep` | `#8E2F43` | gradient end of the mark's inner ring |
| `--plum` | `#43192A` | headings, primary button, device shells |
| `--ink` | `#2A1119` | body text |
| `--ink-soft` | `#6B4753` | secondary text |
| `--ink-faint` | `#80626B` | captions, micro-labels |
| `--line` / `--line-strong` | `#EFDCDF` / `#DFC2C8` | hairlines |

Every text pairing clears WCAG AA against its real composited background. The
one exception is a closed calendar day at 3.46:1, which is an inactive
component and exempt.

## Type

- **Bodoni Moda** — display only, 400–500. A fashion-editorial didone, chosen
  because it is the register this audience already reads. Never below 21px.
- **Plus Jakarta Sans** — everything else, 200–800. Its slightly rounded
  terminals warm up the Bodoni, which is cold on its own.

Scale: 12 (caps micro-labels, optical, not a step) · 14 · 16 · 18 · 21–24 ·
27–34 · 36–60 fluid.

## Motion

200–420ms, `cubic-bezier(.22,.61,.36,1)`. Nothing bounces. Five petals drift
across the hero at ~30s, which is weather, not confetti. All of it is off
under `prefers-reduced-motion`, where the hero shows the end of the booking
story instead of none of it.

## The signature

The hero's laptop and phone are one mechanism: the phone picks a time, and
1.4s later that booking slides onto the laptop's dashboard and the counters
tick up. It demonstrates the entire product without a word — she does nothing,
the booking simply arrives.
