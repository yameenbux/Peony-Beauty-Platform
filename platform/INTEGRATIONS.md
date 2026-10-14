# Two integrations that are not built, and exactly what each one needs

Both were asked for. Neither is a matter of writing the code: each is gated on
an approval from a company that is not us, and the gate is the long part. This
is what the gate actually is, so the waiting can start before the building
does.

---

## Publishing a Story to Instagram from the dashboard

**What was wanted:** she links her Instagram, makes a card, sees a preview, and
taps Publish without opening the app.

**The preview is built.** The Share tab shows the card inside Instagram's own
frame — the progress bar, her handle, the "Send message" strip — so the two
bands that cover the top and bottom of a Story are visible while she is making
it rather than discovered after she has posted it. That part needed nobody's
permission.

**Publishing is possible and is gated on Meta.** The Instagram Content
Publishing API does take Stories. It is a two-step container flow with
`media_type=STORIES`, and it needs four things we do not have:

1. **An Instagram Business account**, linked to a Facebook Page. Stories
   publishing is Business-only — a Creator account cannot do it. A good number
   of lash techs are on Creator, and they would have to switch.
2. **`instagram_business_content_publish`**, which needs **Meta App Review**:
   a live app, a privacy policy URL, a screencast of the flow, and a reviewer
   deciding. Before review you get 25 test users and nobody else.
3. **Business Verification** on the Meta side, to publish on behalf of accounts
   we do not own — which is every account here.
4. **A public HTTPS URL for the image.** This is the one that changes the
   design. Meta's servers fetch the picture; there is no direct upload. A
   signed URL that expires in a minute, a URL behind auth, or an origin that
   blocks datacentre IPs all fail with error 9004.

**What (4) costs us.** The card is currently drawn on a canvas in her browser
and never leaves it. To publish through Meta it has to be uploaded to a public
bucket first, sit there long enough for Meta to fetch it, and then be deleted.
That is a real change to a property worth keeping, and the privacy notice would
have to say so. It should be opt-in per post, not a silent consequence of
linking an account.

**Shape, when it is built:**

```
tenant.ig_user_id          text        -- the Instagram Business account
tenant.ig_token            text        -- long-lived, refreshed every 60 days
tenant.ig_linked_at        timestamptz
```

The token is a credential that posts as her, so it belongs nowhere a browser
can read it: the column stays unreadable to `anon` and `authenticated`, and an
edge function running as `service_role` does the posting. An edge function
`publish-story` would: take the PNG, put it in a public bucket under a random
name, `POST /{ig-user-id}/media` with `image_url` and `media_type=STORIES`,
poll the container until `FINISHED`, `POST /{ig-user-id}/media_publish`, then
delete the file.

**The honest order:** start the Meta app and business verification now, because
that queue is measured in weeks and nothing can be tested until it clears. The
code is a day. Twenty-five test accounts is enough to prove the whole flow in
the meantime.

Until then "Save the picture" and the system share sheet do the same job in two
taps instead of one, and work for TikTok, WhatsApp and everything else as well.

---

## Deposits

**What was raised:** the studio will have to put her own details in during
onboarding. That is right, and it is the whole shape of the feature.

Taking a deposit means money moving from her client to **her**, not to us. That
is Stripe Connect, and it means every studio completes Stripe's own onboarding
— name, address, date of birth, bank account, and an identity document. Stripe
hosts that; we never see any of it. What comes back is an account id.

```
tenant.stripe_account_id      text      -- acct_...
tenant.deposit_pence          int       -- 0 means she takes none
tenant.payouts_ready          boolean   -- Stripe says she can be paid
```

**Where it goes in onboarding: nowhere, at first.** The three-step wizard takes
about ninety seconds and that is why people finish it. Putting a bank account
and a passport photograph in the middle of it would halve the number of studios
who ever get a page. Deposits belong in a fourth step she reaches *later*, from
the dashboard, when she has had a no-show and wants to stop having them — which
is the moment the friction is worth it to her.

Two things must be true before a deposit can be asked for:

- `payouts_ready` is true. Stripe reports this through the
  `account.updated` webhook and it is not instant: identity checks can take
  days. A page that takes deposits into an account that cannot pay out is
  worse than one that takes none.
- She has set `deposit_pence`. The booking page must say the amount **before**
  the client picks a time, not after she has typed her name in.

**What it changes elsewhere:** `book()` stops being the whole transaction. A
booking with a deposit is held unpaid until Stripe confirms the payment, which
means a `pending` status, an expiry so an abandoned checkout releases the slot,
and a webhook that confirms it. The overlap constraint currently covers
`status = 'confirmed'` only, so a pending booking would not hold the slot — a
`pending` state has to be inside the constraint or two people can pay for the
same time.

**Blocked on nothing but a decision and a key.** Unlike Instagram there is no
review queue: a Stripe account and a Connect application is same-day. The
reason it is not built is that it is a fortnight of careful work on the one
code path where a mistake costs somebody real money, and it should not be
started in the same week as three other things.
