# AGENTS.md — Rahama’s Plant Loft

## Project and working style

Rahama’s Plant Loft sells plants and rents plants for events. Its owner currently handles enquiries and consultations in conversational channels. The goal is a practical assistant that helps customers choose, order and rent plants while giving the owner a clear, trustworthy way to price delivery, manage payment and fulfilment, and follow up issues. Onu values plain language, being kept informed about changes, practical demonstrations and honest distinctions between implemented, tested and planned work. Read the current repository and live state before changing anything: this document is a handoff snapshot, not proof that deployments have not changed.

Repository: https://github.com/onubrooks/plant-loft-agent . A separate private working repository and submission materials may exist. Onu submitted the TSG Labs exercise; continue the product as a business project unless asked otherwise. Do not claim measured sales growth, time savings, production readiness or real customer deployment without evidence.

## Current architecture

- Chord hosts the teammate, model, three authored skills and the WhatsApp simulator. Skills: `skills/customer-service.md`, `skills/consultation-sales.md`, `skills/rentals.md` (confirm actual names in repo).
- Four custom tools: `find_products`, `prepare_quote`, `confirm_request`, `get_request`. They call a Supabase Edge Function with narrowly scoped authentication.
- Supabase PostgreSQL holds catalogue, quotes, requests, events, payments and follow-ups. Supabase Storage holds product images. Tool and owner credentials are separate; secrets belong only in protected service configuration, never in skills, source, logs or chat.
- Paystack is configured for test mode. A Google Sheet and Apps Script provide owner dashboard and actions: delivery quote, verified manual bank receipt, fulfilment, reviews and follow-up queue.
- Read `README.md`, `openapi.json`, `supabase/migrations/`, `supabase/functions/plant-loft/`, `integrations/google-sheets/`, `data/`, and `knowledge/` before modifications. Migrations 001–014 were deployed at the last recorded checkpoint; verify actual state and ordering before deploying.

## Business and pricing rules to preserve

- Large Golden and Lady Palms count together: 1–9 large palms cost ₦4,500 each per started 24-hour period; 10 or more cost ₦3,500 each per period. Small plants cost ₦2,000 each per period and do not affect the large-palm tier. Optional setup is ₦20,000.
- Self-transport and owner delivery/collection are separate choices and must be explicit. The owner quotes transport; rental transport covers delivery and collection. Preserve requested return time separately from the number of started 24-hour billing periods. Do not fabricate a courier price, guaranteed slot, deposit or replacement amount.
- Show rental terms before final acceptance: payment before delivery, one-hour notice before finishing (not a collection guarantee), damage at full replacement cost, and another started 24-hour charge for extensions. Confirm current terms with Rahama before real use.
- Customer must explicitly state quantities, plant and pot selections, transport and price-affecting choices. Ask at most two concise questions at a time; remember previous answers. Clarify light and outdoor exposure where needed. Avoid repeated names and boilerplate. Use accurate safety information and show photos when relevant.
- Backend is authoritative for catalogue, eligibility, integer-kobo amounts, quote version and order/payment state. Do not invent codes, totals, stock, payment or delivery status. One clear confirmation saves once; retries recover the existing request without duplicating it. A revised delivery fee and final total require customer acceptance.
- Paystack verification and owner-confirmed bank transfer are independent routes. A customer statement or screenshot alone never proves payment. Preserve exact-amount, version and idempotency checks; leave failed or uncertain payment unpaid pending verification. Do not blindly retry an uncertain payment.
- Customer receipt may complete a purchase. Rental delivery means in use; only owner-recorded collection completes a rental. Log customer return claims and complaints to owner follow-up without falsely confirming collection or unnecessarily pausing the conversation. Low ratings prompt a direct improvement question and owner follow-up; preserve customer feedback.

## Known state, boundaries and risks

- Synthetic catalogue prices, sample orders and Paystack test keys only in the demo. No live WhatsApp number is connected. User reported both purchase and rental flows working, Paystack test checkout verified, and new photo links tested. Earlier automated checks: 19 local Node/Sheet tests and eight hosted SQL suites at their recorded checkpoints; rerun relevant checks after changes.
- Customer-triggered lookup checks Paystack; there is no verified payment webhook or automatic provider-account reissue. Owner quote changes do not proactively message the customer. Chord event-driven runs were not shown to deliver reliably into an existing customer thread; thread identity, least-privilege scopes, event authentication, idempotency, delivery acknowledgement and retry need work.
- Photos are signed links, not in-chat media. Eleven new images were uploaded and linked to catalogue records; filenames may contain ` (1)`. Confirm asset rights, actual plant identity and truthful image descriptions before public/customer use. Avoid publishing private recovery codes, credentials or real customer data.
- Stock checks are snapshots, not concurrent reservations. No production customer identity, booking/dispatch integration, automated refunds, outbound alerting, or live production readiness is established. Reviewer access to the owner dashboard was read-only; do not broaden it or expose owner keys without explicit authorization.
- The policies in `skills/customer-service.md` and `knowledge/shop-policies.md` include fictional sample pickup hours/location, delivery areas, lead times, arrival-damage terms and 14-day aftercare. The skill is the runtime source of truth; update the reference in the same change. Replace samples with Rahama-approved policies before live launch.
- Stale quote versions are rejected deliberately. On one rental the Sheet input had version 1 but current request version was 0. Refresh and inspect existing state before retrying; never silently overwrite a newer quote.

## Development, verification and deployment

Use test data, isolated environments and least-privilege credentials. Do not connect real customer information, live payment keys or production phone numbers without Onu’s explicit authorization. Preserve migrations and existing state; do not casually rerun destructive seed scripts. Distinguish a provider response from a claim and a database update from a delivered customer notification.

Run the relevant local checks from the repository root:

```sh
node --test supabase/functions/plant-loft/workflow.test.mjs integrations/google-sheets/script.test.mjs
```

Inspect applicable SQL regression suites for pricing, stale versions, retries, owner actions and lifecycle; run hosted checks only in a safe test project. For UI changes test a fresh purchase and rental conversation, money/stock edge cases and failure handling; independently inspect saved state. Changes to prompts alone do not prove reliable behavior.

For real launch, agree with Rahama on current stock, pricing, hours, delivery coverage, replacement/aftercare policies and ownership; add trusted identity, durable stock reservations, reliable payment events and reconciliation, proactive channel delivery, monitoring, incident response and a real business WhatsApp integration. Treat these as a roadmap, not completed features. Track deployment problems with observation, evidence, fix, verification, actionable product feedback and remaining uncertainty.
