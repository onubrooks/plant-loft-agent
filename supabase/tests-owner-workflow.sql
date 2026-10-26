begin;
do $$
declare q jsonb; r jsonb; a jsonb; snap jsonb; p jsonb; rejected boolean:=false;
begin
 q:=plant_loft_tool('prepare_quote','{"session_id":"owner-workflow-001","kind":"RENTAL","transport":"BUSINESS_DELIVERY","start_at":"2026-11-01T15:00:00+01:00","end_at":"2026-11-01T20:00:00+01:00","setup":false,"items":[{"category":"GOLDEN_PALM","quantity":5},{"category":"LADY_PALM","quantity":5}],"transport_confirmed":true,"event_logistics":{"venue_access_at":"2026-11-01T13:00:00+01:00","setup_ready_at":"2026-11-01T14:30:00+01:00","onsite_contact":"Demo contact 08000000000"}}');
 assert q->'summary'->>'rental_periods'='1','Five hours bills one day';
 assert (q->'summary'->>'end_at')::timestamptz='2026-11-01T20:00:00+01:00'::timestamptz,'Do not extend collection time';
 r:=plant_loft_tool('confirm_request',jsonb_build_object('quote_code',q->>'quote_code','confirmed',true));
 begin perform plant_loft_prepare_payments((r->>'id')::uuid); exception when raise_exception then rejected:=true; end;
 assert rejected,'No payment before owner approval and total acceptance';
 a:=plant_loft_owner('transport',jsonb_build_object('request_id',r->>'id','fee_kobo',4000000,'owner_reference','synthetic-owner-quote','expected_version',0));
 assert a->'summary'->>'owner_approved'='true','Owner quote approves availability';
 perform plant_loft_owner('transport',jsonb_build_object('request_id',r->>'id','fee_kobo',4000000,'owner_reference','synthetic-owner-quote','expected_version',1));
 assert (select count(*) from public.plant_loft_notification_outbox where request_id=(r->>'id')::uuid)=1,'Quote retry queues one notification';
 r:=plant_loft_tool('confirm_request',jsonb_build_object('quote_code',q->>'quote_code','confirmed',true,'transport_version',1,'confirmed_total_kobo',7500000));
 assert r->>'status'='AWAITING_PAYMENT','Accepted approved rental moves to payment';
 p:=plant_loft_prepare_payments((r->>'id')::uuid);
 assert jsonb_array_length(p)=2,'Checkout and bank-transfer attempts prepared';
 assert (p->0->>'amount_kobo')::bigint=7500000,'Payment uses approved total';
 perform plant_loft_prepare_payments((r->>'id')::uuid);
 assert (select count(*) from public.plant_loft_payment_attempts where request_id=(r->>'id')::uuid)=2,'Payment retries reuse attempts';
 snap:=plant_loft_owner('snapshot','{}');
 assert (snap->'requests'->0->>'created_at')::timestamptz >= (snap->'requests'->1->>'created_at')::timestamptz,'Newest requests first';
end $$;
select 'PASS: actual rental times, one billing day, owner approval, payment readiness, retry outbox and descending requests' as result;
rollback;
