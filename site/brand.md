# Booked In — brand

A booking platform for solo beauty professionals. The name is the phrase they
already use about their own week — *booked in*, *booked out*, *fully booked* —
so it needs no explaining to the only people who matter.

Client pages live at `booked-in.co.uk/<her-name>` and every one of them carries
"Powered by Booked In" in the footer, on every plan. It does not come off at
Pro: it is the only place most people will ever see this brand, and a mark that
disappears the moment somebody starts paying is a mark nobody learns.

What Pro buys instead is her story cards in her own colours, with her logo and
without our mark — because those go out under her name on her own Instagram,
which is a different thing from a page we host for her.

## Two marks, and which is which

`monogram.svg` signs the **brand**. `icon.svg` marks the **product**. Luxury
houses do exactly this: a monogram for the name, a plainer device for the thing.

| | Where |
|---|---|
| **The monogram** | the marketing site's nav and footer, the share card, the privacy and terms pages, the README |
| **The ring** | the favicon, the dashboard, her clients' booking page, and the device mockups on the marketing site |

Each has a `-dark` variant for plum backgrounds, where the light one disappears.

### The monogram

A didone B: hairline serifs, vertical stress, and 1.2 against 3.7 of stroke
contrast. That contrast is the whole point — a bold B with even strokes reads as
a software logo, while a B with real thick and thin reads as a fashion house.
It is built from geometry rather than set in a font, so the mark does not depend
on anything being installed, and it is the same letterform family as the Bodoni
wordmark, which is what makes the lockup hold together.

### The ring

Six slots with one taken: the product in one shape, a day and a time in it that
has gone. Drawn with a dash pattern on two circles rather than six arc paths, so
the slot count is a single number and the taken slot is a dash offset.

The one piece of geometry worth knowing: a round line cap adds half the stroke
width at **each** end of a dash, so the gap in the dash array is the gap you want
to see *plus* the stroke width. Getting that wrong is what made the first attempt
read as a lumpy ring rather than distinct slots.

Six, not eight. Eight looks more refined at 72px and loses the taken slot
entirely at 16px, which is where a favicon lives.

**The free slots have to be visible, and once were not.** They were drawn in
`#EFCFD5`, which is 1.28:1 against the dashboard rail and 1.39:1 against the
booking page — so five slots in six disappeared and the mark rendered as a
single carmine comma with nothing around it. Measured, not guessed: 44 of 220
painted pixels survived the backdrop. They are `#C98D9C` now, 2.4:1 and 2.6:1,
which is a ring you can see while the taken slot still leads it at 4.6:1. The
dark variant had the same fault less badly and moved the same way.

A mark whose point is a count is wrong if you cannot count it. `test_marketing`
checks this now by counting ink, because nothing that reads text can see it.

## Colour

Carmine is a slot that is taken; blush is one that is free; porcelain is what
they sit on. The palette came from a flower originally and survived the rename
because it was never really about the flower — it is a beauty palette that
reads expensive and tests clean.

| Token | Hex | Use |
|---|---|---|
| `--porcelain` | `#FDFAFA` | page ground |
| `--petal` | `#FAEFF0` | raised surfaces, bands |
| `--blush` | `#F2D7DB` | fills on dark |
| `--blush-deep` | `#E5B9C0` | borders on dark, eyebrows on dark |
| `--carmine` | `#B8465C` | accent, eyebrows, prices, the taken slot |
| `--carmine-deep` | `#8E2F43` | gradient end |
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
  The wordmark is BOOKED IN, uppercase, tracked to 0.17em.
- **Plus Jakarta Sans** — everything else, 200–800. Its slightly rounded
  terminals warm up the Bodoni, which is cold on its own.

Scale: 12 (caps micro-labels, optical, not a step) · 14 · 16 · 18 · 21–24 ·
27–34 · 36–60 fluid.

## Motion

200–420ms, `cubic-bezier(.22,.61,.36,1)`. Nothing bounces. Five petals drift
across the hero at ~30s, which is weather, not confetti — they survived the
rename because they read as atmosphere rather than as the old logo. All of it
is off under `prefers-reduced-motion`, where the hero shows the end of the
booking story instead of none of it.

## The signature

The hero's laptop and phone are one mechanism: the phone picks a time, and
1.4s later that booking slides onto the laptop's dashboard and the counters
tick up. It demonstrates the entire product without a word — she does nothing,
the booking simply arrives. It is also the mark, animated: a free slot becomes
a taken one.
