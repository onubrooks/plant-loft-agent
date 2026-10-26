# Plant Loft conversational commerce example

Code for a plant consultation, purchase and event-rental assistant built with Chord, Supabase and a Google Sheet. Includes authored skills, four narrow HTTP tools, server-side pricing, test-payment verification, owner actions and tests.

## Public snapshot

This repository contains code and synthetic catalogue fixtures only. It intentionally excludes recruitment instructions, submission documents, correspondence, recordings, operational histories, private recovery tokens, deployment identifiers and supplied product photos. Its history begins with this cleaned snapshot. The shop-policy examples are fictional and require business-owner approval before real use. Nothing here grants access to the running workspace or database.

## Configure your own deployment

Replace YOUR_PROJECT_REF and YOUR_CHORD_TEAMMATE_ID in the templates with your own deployment values. Use separate private agent/owner keys and Paystack test credentials in server secrets; never put them in the skill or repository. Apply migration 001, seed.sql, then migrations 002–014 in order. Supply your own appropriately licensed product images under the configured Storage paths. Deploy the Edge Function, import openapi.json into Chord, configure the private auth header and publish the three skills. The optional Sheet uses its own owner key in Script Properties.

Run: node --test supabase/functions/plant-loft/workflow.test.mjs integrations/google-sheets/script.test.mjs

## Limits

Synthetic stock is not a concurrent reservation system. Channel identity is a prototype workaround. Automatic customer messaging, live WhatsApp deployment, refunds, payment webhooks and real operations are not configured. Public code is not a claim of production readiness.

## Policy source of truth

`skills/customer-service.md` is the authoritative policy text read by the teammate. `knowledge/shop-policies.md` is a reference copy of its fictional sample terms. Edit the skill first, update that reference in the same change, and republish the skill before testing. The samples require owner approval or replacement before launch.
