# Plant Loft 🌿
## Less back-and-forth. More room to grow.

An AI sales and event-rental assistant for **Rahama’s Plant Loft**, built to turn a useful conversation into an actionable order.

Small businesses often sell through chat. That makes every unanswered message a potential lost sale—and every repeated consultation another task for an already busy owner. Plant Loft brings product advice, pricing, payments and fulfilment into one conversation, with a simple owner dashboard for the decisions that still need a person.

## A real business problem

I interviewed the owner to understand her workflow. Long consultations did not always turn into sales, staff departures left nobody available to answer potential customers, and Instagram enquiries could wait too long for a reply.

The assistant handles repeat questions and gathers the details needed to move an order forward. It runs on Chord’s WhatsApp simulator; Instagram is not integrated. Time saved and conversion improvements have not yet been measured.

## What it does

- **Plant consultations:** find plants by name, budget and conditions; share product-photo links, care information and safety guidance.
- **Purchases:** collect explicit quantities, pots and pickup/delivery preferences, then save a priced request.
- **Event rentals:** combine Golden and Lady Palms for volume pricing, calculate started 24-hour periods and add optional setup.
- **Payments:** offer Paystack test checkout and a separate owner-verified bank-transfer route. A customer saying “I’ve paid” never establishes payment.
- **Owner operations:** use Google Sheets to quote delivery fees, confirm bank receipts, record delivery/collection and review customer issues.
- **Aftercare and feedback:** provide purchased-plant care guidance and capture product/service ratings, with low scores routed for follow-up.

## How it works

| Component | Responsibility |
|---|---|
| Chord + three authored skills | Conversation, business context and workflow guidance |
| Four HTTP tools | Catalogue search, quote preparation, request confirmation and request lookup/actions |
| Supabase Edge Function + PostgreSQL | Validate inputs, calculate prices, persist orders and enforce lifecycle rules |
| Supabase Storage | Time-limited product-photo links |
| Paystack | Test checkout and provider payment verification |
| Google Sheets + Apps Script | Owner controls and sales-funnel visibility |

The model conducts the conversation; the backend owns money and order state. Prices use integer kobo. Accepted delivery fees are versioned, retries recover existing requests, and owner actions use a separate private key. A rental is not complete merely because the customer reports a return: the owner must record collection.

## Run your own deployment

1. Create a dedicated Supabase project and Chord workspace. Install Node.js and the Supabase CLI.
2. Apply migration 001, then `supabase/seed.sql`, then migrations 002–014 in filename order.
3. Replace `YOUR_PROJECT_REF` and `YOUR_CHORD_TEAMMATE_ID` in the templates.
4. Upload the supplied example images to the private Storage bucket `plant-loft-images`, using their basenames; confirm rights before wider use.
5. Set separate server-only agent/owner keys, Supabase service credentials and Paystack **test** credentials. Never commit them.
6. Deploy the `plant-loft` Edge Function, import `openapi.json` into Chord and configure each tool’s private authentication header.
7. Publish the three files in `skills/` and assign them to the teammate.
8. Optionally install `integrations/google-sheets/Code.gs`; put the owner key in Script Properties, authorize the script and run `setupDashboard`.

Run the local adapter and Sheet checks:

```sh
node --test supabase/functions/plant-loft/workflow.test.mjs integrations/google-sheets/script.test.mjs
```

## Policy source of truth

`skills/customer-service.md` is the authoritative policy text read by the teammate. `knowledge/shop-policies.md` is its reference copy. Edit the skill first, update the reference in the same change and republish before testing.

Catalogue prices and sample shop policies are fictional. Replace pickup details, hours, delivery coverage, lead times, arrival-damage terms and aftercare promises with owner-approved terms before serving customers.

## Current boundaries

This is a working prototype using synthetic data and test payments. Stock checks are snapshots, not concurrent reservations. Payment verification runs on request; webhooks and automatic customer notifications are not implemented. Photos open as links. Live WhatsApp deployment, production customer identity, automatic refunds and operational alerting remain future work.

The repository includes the skills, tool contracts, backend, migrations, synthetic catalogue fixtures, Sheet script and tests. It excludes credentials, deployment identifiers, private order histories and private operational data. Bring your own configuration; review image rights before wider use.

Built by [Onu Abah](https://onubrooks.github.io) · Financial data engineering, backend systems and applied AI.
