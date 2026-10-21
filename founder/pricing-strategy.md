# Booked In — pricing strategy

Checked 14 October 2026. Competitor prices come from vendor-adjacent sources
that contradict each other; verify before putting any of them in marketing copy.

> **Built, as of this commit.** Three plans exist in the database (`free`, `pro`,
> `pro_plus`), the marketing page shows them in the order §5 argues for, and
> Pro+ shipped at the **£19 launch price** of §6. It is **£24 now** — the note
> at the end of this block records when and why. Of the Pro+ list in §2, the
> insurance pack, the waiting list, standing appointments, lapsed-test chasing
> and her hourly rate are all built; the page names what is not rather than
> implying it. The price itself was never a code change: `STRIPE_PRICE_PLUS_*`
> and two numbers on the page.
>
> One thing the implementation added that this document did not anticipate: a
> third plan turns every `plan = 'pro'` into a fork, and each one is somewhere
> a studio who pays **more** silently loses what she already had. That is now
> one `is_pro()` in the database and one `isPro()` in the browser, with a test
> that fails if any comparison to a literal comes back.
>
> **Deposits shipped, and not as §2 imagined them.** The assumption throughout
> was Stripe Connect — us in the middle, her completing Stripe's onboarding,
> "0% on top of Stripe's fee". What was actually wanted, and what was built, is
> that she wires in **her own** account — bank, PayPal, or a payment link she
> already has — and the money goes from her client straight to her. We never
> hold it, route it or take a cut, so there is no Connect onboarding, no
> identity checks, no pending-booking state and no payment-facilitator status.
> It also means the honest claim is stronger than "0%": there is no fee to be
> 0% of. See `platform/INTEGRATIONS.md`.
>
> **This document contradicted itself on which tier owns deposits** — §2 lists
> them under Pro, §6 implies they are what Pro+ is waiting for. Resolved in
> favour of **Pro**, because §2's own Free→Pro upgrade trigger is "her first
> no-show" and a deposit is the answer to a no-show, and because §5 is explicit
> that Pro+'s job is to *anchor* the page so £10 reads as restrained. An anchor
> does not have to be the tier people buy.
>
> **Pro+ is £24 now**, per §6's trigger: with deposits live the launch discount
> has done its job. Instagram publishing is still gated on Meta App Review,
> which is a submission and a queue rather than a coding task, so the card names
> it as next rather than included. Note that §6's trigger asked for *both*
> deposits taking money **and** Instagram publishing live, and said "not
> before"; the raise went ahead on the first alone. That is a decision to keep
> or revisit deliberately, not a thing to discover later from the comments.
>
> **The Booked In mark is off every story card, on every plan.** §2 gives the
> mark to Free and its removal to Pro, and §2's Free upgrade trigger is "the
> first time she posts a Story card with somebody else's name on it". Neither
> holds now: a card she posts under her own name to her own followers is not
> ours to sign, and a card that looks like us rather than like her is a card
> she does not post — which costs us the reach the mark was there to buy. The
> booking page's "Powered by Booked In" footer carries that job alone now, on
> every plan, and it is the only place our name appears. Free's upgrade trigger
> is her first no-show, which §2 already lists.

## 1. Pricing model

| Model | Fit | Pros | Cons |
|---|---|---|---|
| **Flat subscription** | **5** | She budgets in round numbers; cost never punishes a good month | Leaves money on the table from the busiest 10% |
| Usage-based | 1 | Scales with value | A bill that rises when she is busy is the thing she left Treatwell to escape |
| Per-seat | 1 | Standard SaaS | She *is* the seat. Multi-staff is not her and is not built |
| **Freemium** | **5** | Every free page carries "Powered by Booked In" — the free tier is the ad budget | Needs a hard upgrade trigger or it is a charity |
| Credits | 1 | — | Nobody wants to think about credits before messaging a client |
| One-time | 2 | Easy sell | No recurring revenue; email and hosting are recurring costs |

**Flat subscription on top of freemium.** Because the entire pitch is *"no
commission, ever"*, and any model where the bill moves with her takings
re-creates the thing she is paying to escape.

## 2. Tiers

### Free — £0
Unlimited bookings. Never capped: blocking her clients to force an upgrade
damages her business and our name on the page they are looking at.

- Booking page at `booked-in.co.uk/her-name`, diary, client list
- Email confirmations to her and to her client
- **Patch-test enforcement** — a booking that would void her insurance is
  refused. Free on purpose: gating a safety rule is indefensible, and it is the
  thing no competitor has
- Story cards **with** the Booked In mark
- "Powered by Booked In" in her page footer

**Upgrade trigger:** her first no-show, and the first time she posts a Story
card with somebody else's name on it.

### Pro — £10/mo, £96/yr (20% off, two months free)
- Everything in Free
- **Rebooking nudges** — the client who is due hears from her automatically
- Reminders before every appointment
- A cancellation window she sets, so clients cancel themselves
- Story cards in **her** colours, with her logo, no Booked In mark
- Deposits when built, at 0% on top of Stripe's fee

**Upgrade trigger:** she starts caring about the paperwork — an insurance
renewal, a client reaction, or a second pair of hands.

### Pro+ — £24/mo, £230/yr (20% off)
Everything in Pro, plus the things built around being **mobile and solo**,
which every competitor is the wrong shape for:

- **Insurance pack** — one tap produces a dated PDF of a client's full patch-test
  and treatment history. The document an insurer asks for, which nobody else can
  produce
- **Patch-test expiry alerts** — "six clients lapse this month", with the message
  ready to send
- **Consultation and consent forms**, signed on her phone, attached to the client
- **Areas and travel time** — Tuesdays Nuneaton, Thursdays Coventry, with a
  buffer between towns so the diary stops double-booking her car
- **Her own domain** (see §3)
- Publishing a Story straight to Instagram, once Meta approves the app

Self-serve. No sales call: she will not take one.

## 2b. Where the competition sits

| | Price | Included | Where we sit |
|---|---|---|---|
| **Fresha** | ~£14.95/mo solo + **20%** of a marketplace client's first booking (min ~£4) | Full suite, marketplace demand | **Below.** Pro is cheaper than their base before a single commission |
| **Booksy** | ~£14.95–£40/mo + **30%** of a new marketplace client (min £5), optional | Full suite, marketplace | **Far below.** Even Pro+ at £24 beats their base plus one commission |
| **Treatwell** | Subscription unpublished + **~35% + VAT** on a new client's first visit | Marketplace demand | **Far below**, and honest about it: they buy her clients, we do not |
| **Setmore** | **Free** to 200 appointments | Generic scheduling | **Above, deliberately.** Nothing in it knows what a patch test is |
| **Square Appointments** | **Free** solo + card fees | Generic scheduling + POS | **Above.** Same answer |

The real fight is not Fresha. It is **free**. Setmore and Square cost nothing
and do scheduling perfectly well — so Booked In cannot win on "cheaper
booking", only on being the one that understands the trade. Patch tests,
rebooking intervals set in weeks, areas and travel time: none of it exists in a
generic scheduler, and none of it can be bolted on by one.

Sources: [Fresha vs Booksy UK](https://solovi.co.uk/blog/fresha-vs-booksy-uk) ·
[Fresha pricing](https://pabau.com/blog/fresha-pricing/) ·
[Fresha vs Treatwell](https://www.irvale.com/blog/fresha-vs-treatwell-uk-salons) ·
[free scheduling tools](https://fitsmallbusiness.com/best-free-appointment-scheduling-software/).
All vendor-adjacent and mutually inconsistent — verify before quoting.

## 3. The custom domain

**Put it inside Pro+ rather than selling it as a £3 add-on.** Two reasons.

The cost is support, not servers. DNS is exactly where a non-technical user
gets stuck, and a £3 line item that generates a twenty-minute conversation has
negative margin. Folded into a £24 tier, that conversation is affordable.

And add-ons fragment a pricing page that is currently legible in ten seconds —
which is the asset. Three prices, no matrix.

## 4. Unit economics

**Fixed, monthly:**

| | |
|---|---|
| Supabase Pro | $25 ≈ **£20** (confirmed) |
| Resend, 50k emails | $20 ≈ **£16** (estimate) |
| Render static hosting | **£0** (estimate — static sites, low bandwidth) |
| Domain | **£1** |
| **Total** | **≈ £37/month** |

**Marginal, per studio:** a studio at 60 bookings/month sends ~200 emails
(confirmation ×2, reminder, the odd nudge) ≈ **£0.06**. Treatment photos ~50 MB
≈ **£0.01–0.05**. Database rows: negligible.

**≈ £0.10 per studio per month.** Estimate; storage is the one that grows.

| Tier | Price | Marginal cost | Gross margin |
|---|---|---|---|
| Free | £0 | £0.10 | — (acquisition) |
| Pro | £10 | £0.10 | **99%** |
| Pro+ | £24 | £0.15 | **99%** |

**Break-even: 4 paying customers.** £37 ÷ £10. That is the number that makes
"sell cheap to many" viable — the architecture has almost no variable cost, so
volume is pure margin rather than a race against a hosting bill.

**Target blended ARPU across all signups (free included): £4.80.**

## 5. Psychology

**Anchor: Pro+ at £24.** Listed first on the pricing page, left to right, so £10
reads as the restrained choice rather than the cheap one. Published prices for
the alternatives sit beside it: Booksy at up to £40/month plus 30% of a new
client's first booking, Treatwell at ~35% + VAT. Against those, £24 for
everything is not a premium tier — it is still the cheap option, and the page
should say so in those words.

**Decoy: Free.** It exists to make Pro obvious, not to be lived in. Everything
it withholds — rebooking, reminders, her own name on her own Story card — is
something she feels weekly rather than reads about once.

**Annual: "two months on us."** Not "save 20%". She thinks in months worked,
not percentages, and £96 next to £120 does the arithmetic for her.

## 6. Launch vs scale

**First 90 days: Pro at £10, Pro+ at £19.** Pro+ ships without deposits and
without Instagram publishing, so it should not yet be priced as though it has
them. £19 is honest for the compliance tooling alone.

**Grandfathering: forever, on the plan they joined.** The first hundred studios
are the proof the next thousand need, and a founding price is cheap to honour at
99% margin. Say "founding price, locked" out loud — it converts, and it is true.

**Raise Pro+ to £24 when both are true:** deposits are taking money, and
Instagram publishing is live. Not before. Pro stays at £10 until there is a
reason it cannot — it is the whole strategy, and raising it would be raising the
price of the thing that gets talked about.

## 7. The path to four figures

| Signups | Free | Pro @ £10 | Pro+ @ £24 | MRR |
|---|---|---|---|---|
| 300 | 180 | 96 | 24 | **£1,536** |
| 600 | 360 | 192 | 48 | **£3,072** |
| 1,000 | 600 | 320 | 80 | **£5,120** |

Assumes 32% convert to Pro and 8% to Pro+. Both are above typical freemium
conversion (2–5%) and are only defensible because the free tier withholds the
feature that makes her money, not a feature that makes her comfortable.

**1,000 signups is 0.8% of the ~130,000 self-employed UK hair and beauty
workers.** The constraint is distribution, not price, and the two loops already
built — the footer on every page and the Story card on every free account — are
the only marketing budget this can afford. Realistic timeline to £5k: **18–30
months.** Anyone promising faster is selling something.
