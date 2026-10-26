-- Run in SQL Editor. All test writes are rolled back.
begin;
do $$
declare q jsonb; first_request jsonb; replay jsonb; bad boolean;
 base jsonb := '{"session_id":"test-session-001","kind":"RENTAL","transport":"SELF_PICKUP","start_at":"2026-11-10T10:00:00+01:00","end_at":"2026-11-11T10:00:00+01:00","transport_confirmed":true,"event_logistics":{"venue_access_at":"2026-11-10T08:00:00+01:00","setup_ready_at":"2026-11-10T09:30:00+01:00","onsite_contact":"Demo contact 08000000000"}}';
begin
 q:=plant_loft_tool('prepare_quote',base||'{"items":[{"category":"GOLDEN_PALM","quantity":9}]}');
 assert (q#>>'{summary,goods_or_rental_kobo}')::bigint=4050000,'9-palm price';
 q:=plant_loft_tool('prepare_quote',base||'{"items":[{"category":"GOLDEN_PALM","quantity":6},{"category":"LADY_PALM","quantity":4},{"category":"SMALL_PLANT","quantity":2}],"setup":true,"end_at":"2026-11-12T10:00:00+01:00"}');
 assert (q#>>'{summary,known_subtotal_kobo}')::bigint=9800000,'Mixed palms, small plants, two periods, setup';
 q:=plant_loft_tool('prepare_quote',base||'{"items":[{"category":"GOLDEN_PALM","quantity":9},{"category":"SMALL_PLANT","quantity":1}]}');
 assert (q#>>'{summary,goods_or_rental_kobo}')::bigint=4250000,'Small plants excluded from tier';
 q:=plant_loft_tool('prepare_quote',base||'{"items":[{"category":"GOLDEN_PALM","quantity":10}],"transport":"BUSINESS_DELIVERY","transport_confirmed":true}');
 assert (q#>>'{summary,goods_or_rental_kobo}')::bigint=3500000,'10-palm rate';
 assert q#>'{summary,final_total_kobo}'='null'::jsonb,'Unknown transport blocks final total';
 bad:=false;
 begin perform plant_loft_tool('confirm_request',jsonb_build_object('session_id','test-session-001','quote_id',q->>'quote_id','confirmed',false)); exception when raise_exception then bad:=true; end;
 assert bad,'Confirmation required';
 first_request:=plant_loft_tool('confirm_request',jsonb_build_object('session_id','test-session-001','quote_id',q->>'quote_id','confirmed',true));
 update plant_loft_quotes set expires_at=now()-interval '1 hour' where id=(q->>'quote_id')::uuid;
 replay:=plant_loft_tool('confirm_request',jsonb_build_object('session_id','test-session-001','quote_id',q->>'quote_id','confirmed',true));
 assert first_request->>'id'=replay->>'id','Replay returns same result even after quote expiry';
 assert (select count(*) from plant_loft_requests where quote_id=(q->>'quote_id')::uuid)=1,'Exactly one request';
 replay:=plant_loft_tool('get_request',jsonb_build_object('session_id','different-session','quote_id',q->>'quote_id'));
 assert replay->>'found'='false','Cross-session lookup';
 q:=plant_loft_tool('prepare_quote',base||'{"items":[{"category":"GOLDEN_PALM","quantity":2}],"end_at":"2026-11-11T11:00:00+01:00"}');
 assert q#>>'{summary,rental_periods}'='2','Twenty-five hours bills two started days';
 assert (q#>>'{summary,end_at}')::timestamptz='2026-11-11T11:00:00+01:00'::timestamptz,'Actual collection time remains unchanged';
 q:=plant_loft_tool('prepare_quote','{"session_id":"test-session-001","kind":"SALE","transport":"SELF_PICKUP","items":[{"product_id":"plant-01","pot_id":"pot-19","quantity":2}],"transport_confirmed":true}');
 assert (q#>>'{summary,known_subtotal_kobo}')::bigint=2300000,'Sale uses stored plant and pot prices';
 assert not has_function_privilege('anon','public.plant_loft_tool(text,jsonb)','EXECUTE'),'Anonymous RPC forbidden';
 assert not has_table_privilege('anon','public.plant_loft_requests','SELECT'),'Anonymous record access forbidden';
end $$;
select 'PASS: rental boundaries, mixed tiers, duration, transport, confirmation, replay, session scope, sale pricing, permissions' as result;
rollback;


begin;
do $$
declare q jsonb; r jsonb; replay jsonb; quoted jsonb; bad boolean; snap jsonb;
begin
 q:=plant_loft_tool('prepare_quote','{"session_id":"test-recovery-002","kind":"RENTAL","transport":"BUSINESS_DELIVERY","start_at":"2026-11-10T10:00:00+01:00","end_at":"2026-11-12T10:00:00+01:00","setup":true,"items":[{"category":"GOLDEN_PALM","quantity":6},{"category":"LADY_PALM","quantity":4},{"category":"SMALL_PLANT","quantity":2}],"transport_confirmed":true,"event_logistics":{"venue_access_at":"2026-11-10T08:00:00+01:00","setup_ready_at":"2026-11-10T09:30:00+01:00","onsite_contact":"Demo contact 08000000000"}}');
 assert q->>'quote_code' like 'PL-%','Private tracking code returned';
 r:=plant_loft_tool('confirm_request',jsonb_build_object('quote_code',q->>'quote_code','confirmed',true));
 replay:=plant_loft_tool('get_request',jsonb_build_object('quote_code',q->>'quote_code'));
 assert replay->>'id'=r->>'id','Recovery without model session/quote IDs';
 replay:=plant_loft_tool('get_request','{"quote_code":"PL-not-a-real-code"}');
 assert replay->>'found'='false','Invalid capability cannot retrieve';
 quoted:=plant_loft_owner('transport',jsonb_build_object('request_id',r->>'id','fee_kobo',1500000,'owner_reference','TEST-ROUND-TRIP','expected_version',0));
 assert (quoted#>>'{summary,final_total_kobo}')::bigint=11300000,'98000 plus 15000';
 assert quoted->>'status'='AWAITING_CUSTOMER_CONFIRMATION','Revised total needs acceptance';
 replay:=plant_loft_owner('transport',jsonb_build_object('request_id',r->>'id','fee_kobo',1500000,'owner_reference','TEST-ROUND-TRIP','expected_version',0));
 assert (replay#>>'{summary,transport_version}')::integer=1,'Same owner operation is idempotent';
 bad:=false;begin perform plant_loft_owner('transport',jsonb_build_object('request_id',r->>'id','fee_kobo',1600000,'owner_reference','TEST-CHANGED','expected_version',0));exception when raise_exception then bad:=true;end;
 assert bad,'Stale owner update rejected';
 replay:=plant_loft_tool('confirm_request',jsonb_build_object('quote_code',q->>'quote_code','confirmed',true));
 assert replay->>'confirmation_required'='true','Bare yes cannot accept changed total';
 bad:=false;begin perform plant_loft_tool('confirm_request',jsonb_build_object('quote_code',q->>'quote_code','confirmed',true,'transport_version',1,'confirmed_total_kobo',11200000));exception when raise_exception then bad:=true;end;
 assert bad,'Wrong amount cannot accept';
 replay:=plant_loft_tool('confirm_request',jsonb_build_object('quote_code',q->>'quote_code','confirmed',true,'transport_version',1,'confirmed_total_kobo',11300000));
 assert replay#>>'{summary,transport_accepted}'='true','Exact total accepted';
 assert replay->>'status'='AWAITING_PAYMENT','Approved rental is ready for payment after total acceptance';
 assert (select count(*) from plant_loft_requests where id=(r->>'id')::uuid)=1,'Still one request';
 snap:=plant_loft_owner('snapshot','{}');
 assert not (snap::text like '%'||(q->>'quote_code')||'%'),'Public-facing snapshot omits tracking capability';
 assert not has_function_privilege('anon','public.plant_loft_owner(text,jsonb)','EXECUTE'),'Owner RPC not public';
 assert not has_function_privilege('authenticated','public.plant_loft_owner(text,jsonb)','EXECUTE'),'Normal auth cannot call owner RPC';
end $$;
select 'PASS: private-code recovery, owner-only fee, totals, audit, idempotency, stale update and exact customer acceptance' as result;
rollback;


begin;
do $$
declare q jsonb; looked jsonb; saved jsonb; replay jsonb;
begin
 q:=plant_loft_tool('prepare_quote','{"session_id":"demo-confirm-state-20261024","kind":"SALE","transport":"BUSINESS_DELIVERY","items":[{"product_id":"plant-01","pot_id":"pot-19","quantity":1}],"transport_confirmed":true}');
 looked:=plant_loft_tool('get_request',jsonb_build_object('quote_code',q->>'quote_code'));
 assert looked->>'found'='true' and looked->>'request_saved'='false' and looked->>'quote_found'='true','Unsaved quote is valid and distinct from a missing resource';
 assert looked->>'state'='QUOTE_AWAITING_SAVE','Explicit unsaved state';
 assert looked->>'quote_code'=q->>'quote_code','Exact capability preserved';
 assert looked->>'session_id' is null,'No synthetic identity leak';
 saved:=plant_loft_tool('confirm_request',jsonb_build_object('quote_code',q->>'quote_code','confirmed',true));
 assert saved->>'status'='AWAITING_OWNER_REVIEW','Pending delivery does not block initial save';
 looked:=plant_loft_tool('get_request',jsonb_build_object('quote_code',q->>'quote_code'));
 assert looked->>'found'='true' and looked->>'state'='REQUEST_SAVED','Saved result explicit';
 replay:=plant_loft_tool('confirm_request',jsonb_build_object('quote_code',q->>'quote_code','confirmed',true));
 assert replay->>'id'=saved->>'id','Repeated yes reuses request';
 looked:=plant_loft_tool('get_request','{"quote_code":"PL-does-not-exist"}');
 assert looked->>'found'='false' and looked->>'quote_found'='false' and looked->>'state'='QUOTE_NOT_FOUND','Invalid quote distinguished';
end $$;
select 'PASS: valid unsaved quote, one save, repeated yes, missing quote and no identity leak' as result;
rollback;


begin;
do $$
declare a jsonb; b jsonb; c jsonb; q jsonb; r jsonb;
begin
 a:=public.plant_loft_tool('find_products','{"session_id":"cx-test-001","product_kind":"plant","budget_kobo":500000}');
 if (a->>'total_matches')::integer<>0 or a->>'has_more'<>'false' then raise exception 'Budget zero match must be complete'; end if;
 a:=public.plant_loft_tool('find_products','{"session_id":"cx-test-001","product_kind":"plant","limit":2}');
 b:=public.plant_loft_tool('find_products','{"session_id":"cx-test-001","product_kind":"plant","limit":2,"offset":2}');
 if jsonb_array_length(a->'products')<>2 or a->>'has_more'<>'true' or a->'products'->0->>'id'=b->'products'->0->>'id' then raise exception 'Pagination broken'; end if;
 c:=public.plant_loft_tool('find_products','{"session_id":"cx-test-001","product_kind":"plant","query":"Snake Plant"}');
 if c->'products'->0->'care'->>'light' is null then raise exception 'Care missing'; end if;
 q:=public.plant_loft_tool('prepare_quote','{"session_id":"cx-test-001","kind":"SALE","transport":"BUSINESS_DELIVERY","items":[{"product_id":"plant-01","pot_id":"pot-19","quantity":1}],"delivery_details":{"area":"Demo Area","address":"12 Example Road","phone":"07000000000","landmark":"Demo gate"},"transport_confirmed":true}');
 if q->>'customer_reference' !~ '^[0-9]{5}$' then raise exception 'Short reference invalid'; end if;
 a:=public.plant_loft_tool('get_request',jsonb_build_object('quote_code',q->>'quote_code'));
 if a->>'found'<>'true' or a->>'request_saved'<>'false' or a->>'quote_persisted'<>'true' then raise exception 'Quote existence must not look like a missing resource'; end if;
 r:=public.plant_loft_tool('confirm_request',jsonb_build_object('quote_code',q->>'quote_code','confirmed',true));
 if r->>'customer_reference'<>q->>'customer_reference' or r->'summary'->'delivery_details'->>'area'<>'Demo Area' then raise exception 'Reference or contact lost'; end if;
 a:=public.plant_loft_tool('confirm_request',jsonb_build_object('quote_code',q->>'quote_code','confirmed',true));
 if a->>'id'<>r->>'id' then raise exception 'Duplicate request'; end if;
 a:=public.plant_loft_tool('get_request',jsonb_build_object('quote_code',q->>'customer_reference'));
 if a->>'quote_found'<>'false' then raise exception 'Short reference must not grant access'; end if;
end $$;
select 'PASS: budget, pagination, care, short display reference, contact, replay and no short-code access' as result;
rollback;


begin;
do $$
declare p jsonb:='{"session_id":"retry-guard-test-001","kind":"SALE","transport":"SELF_PICKUP","items":[{"product_id":"plant-01","pot_id":"pot-19","quantity":1}],"transport_confirmed":true}';
 q jsonb; again jsonb; saved jsonb; after_save jsonb; fresh jsonb;
begin
 q:=plant_loft_tool('prepare_quote',p);
 again:=plant_loft_tool('prepare_quote',p);
 assert again->>'quote_id'=q->>'quote_id','Same selection reuses the stored draft';
 saved:=plant_loft_tool('confirm_request',jsonb_build_object('quote_code',q->>'quote_code','confirmed',true));
 after_save:=plant_loft_tool('prepare_quote',p);
 assert after_save->>'id'=saved->>'id' and after_save->>'request_saved'='true','A model re-quote must recover the saved request';
 assert after_save->>'customer_reference'=q->>'customer_reference','Reference stays stable';
 assert (select count(*) from public.plant_loft_quotes where session_id=p->>'session_id')=1,'No extra draft on retry';
 assert (select count(*) from public.plant_loft_requests where session_id=p->>'session_id')=1,'No extra request on retry';
 fresh:=plant_loft_tool('prepare_quote',p||'{"new_order":true}');
 assert fresh->>'quote_id'<>q->>'quote_id','Explicit new order remains possible';
 again:=plant_loft_tool('prepare_quote',p||'{"session_id":"different-session-001"}');
 assert again->>'quote_id'<>q->>'quote_id','Never deduplicate across sessions';
 p:=p||'{"session_id":"delivery-retry-test-001","transport":"BUSINESS_DELIVERY","delivery_details":{"area":"Demo Area","phone":"07000000000"},"transport_confirmed":true}';
 q:=plant_loft_tool('prepare_quote',p);
 saved:=plant_loft_tool('confirm_request',jsonb_build_object('quote_code',q->>'quote_code','confirmed',true));
 perform plant_loft_owner('transport',jsonb_build_object('request_id',saved->>'id','fee_kobo',500000,'owner_reference','synthetic-retry-fee','expected_version',0));
 saved:=plant_loft_tool('confirm_request',jsonb_build_object('quote_code',q->>'quote_code','confirmed',true,'transport_version',1,'confirmed_total_kobo',1650000));
 after_save:=plant_loft_tool('prepare_quote',p);
 assert after_save->>'id'=saved->>'id','Delivery retry keeps saved request';
 assert after_save->'summary'->>'transport_accepted'='true' and after_save->'summary'->>'final_total_kobo'='1650000','Retry must preserve accepted owner fee';
end $$;
select 'PASS: repeated draft, repeated save, stable reference, explicit new order and session isolation' as result;
rollback;


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


begin;
do $$
declare q jsonb; r jsonb; a jsonb; rejected boolean; code text; rid uuid; rental jsonb;
begin
 rejected:=false;
 begin perform plant_loft_tool('prepare_quote','{"session_id":"lifecycle-no-qty","kind":"SALE","transport":"SELF_PICKUP","items":[{"product_id":"plant-09","pot_id":"pot-19"}],"transport_confirmed":true}');exception when raise_exception then rejected:=true;end;
 assert rejected,'Missing quantity rejected';
 q:=plant_loft_tool('prepare_quote','{"session_id":"lifecycle-sale-001","kind":"SALE","transport":"BUSINESS_DELIVERY","items":[{"product_id":"plant-09","pot_id":"pot-19","quantity":1}],"transport_confirmed":true}');
 code:=q->>'quote_code';r:=plant_loft_tool('confirm_request',jsonb_build_object('quote_code',code,'confirmed',true));rid:=(r->>'id')::uuid;
 rejected:=false;begin perform plant_loft_tool('get_request',jsonb_build_object('quote_code',code,'customer_action','received','confirmed',true));exception when raise_exception then rejected:=true;end;
 assert rejected,'Unpaid receipt cannot fulfil order';
 rejected:=false;begin perform plant_loft_lifecycle(rid,'confirm_transfer',jsonb_build_object('funds_received',true),'CUSTOMER');exception when raise_exception then rejected:=true;end;
 assert rejected,'Customer cannot confirm bank funds';
 a:=plant_loft_owner('transport',jsonb_build_object('request_id',rid,'fee_kobo',250000,'owner_reference','lifecycle-delivery','expected_version',0));
 r:=plant_loft_tool('confirm_request',jsonb_build_object('quote_code',code,'confirmed',true,'transport_version',1,'confirmed_total_kobo',1800000));
 -- A payment claim/status read cannot mark paid.
 r:=plant_loft_tool('get_request',jsonb_build_object('quote_code',code,'check_payment',true));assert r->'summary'->>'payment_status'='UNPAID','Payment claim stays unpaid';
 rejected:=false;begin perform plant_loft_owner('confirm_transfer',jsonb_build_object('request_id',rid,'amount_kobo',1700000,'bank_reference','lifecycle-bank-001','expected_version',1,'confirmed_by','Rahama test','funds_received',true));exception when raise_exception then rejected:=true;end;
 assert rejected,'Partial payment rejected';
 rejected:=false;begin perform plant_loft_owner('confirm_transfer',jsonb_build_object('request_id',rid,'amount_kobo',1800000,'bank_reference','lifecycle-bank-001','expected_version',0,'confirmed_by','Rahama test','funds_received',true));exception when raise_exception then rejected:=true;end;
 assert rejected,'Stale version rejected';
 a:=jsonb_build_object('request_id',rid,'amount_kobo',1800000,'bank_reference','lifecycle-bank-001','expected_version',1,'confirmed_by','Rahama test','funds_received',true);
 perform plant_loft_owner('confirm_transfer',a);perform plant_loft_owner('confirm_transfer',a);
 assert (select count(*) from plant_loft_receipts where request_id=rid)=1,'Transfer retries produce one receipt';
 r:=plant_loft_tool('get_request',jsonb_build_object('quote_code',code));assert r->'summary'->>'payment_status'='OWNER_CONFIRMED_TRANSFER_TEST','Customer reads owner confirmation';
 rejected:=false;begin perform plant_loft_tool('get_request',jsonb_build_object('quote_code',code,'customer_action','review','overall_feedback','too early'));exception when raise_exception then rejected:=true;end;assert rejected,'Early review rejected';
 perform plant_loft_owner('delivered',jsonb_build_object('request_id',rid,'confirmed',true));
 r:=plant_loft_tool('get_request',jsonb_build_object('quote_code',code,'customer_action','received','confirmed',true));assert r->>'status'='COMPLETED','Customer receipt completes sale';
 perform plant_loft_owner('delivered',jsonb_build_object('request_id',rid,'confirmed',true));
 r:=plant_loft_tool('get_request',jsonb_build_object('quote_code',code));assert r->>'status'='COMPLETED','Late owner confirmation does not regress completion';
 a:=jsonb_build_object('quote_code',code,'customer_action','review','product_rating',4,'service_rating',5,'product_feedback','Healthy plant','service_feedback','Helpful assistant');
 perform plant_loft_tool('get_request',a);r:=plant_loft_tool('get_request',a);assert r->>'review_saved'='true','Review persisted';
 assert (select count(*) from plant_loft_reviews where request_id=rid)=1,'Repeated review creates no duplicate';
 rejected:=false;begin perform plant_loft_tool('get_request',a||'{"product_rating":6}');exception when raise_exception then rejected:=true;end;assert rejected,'Invalid rating rejected';
 rejected:=false;begin perform plant_loft_tool('get_request',a||'{"product_rating":2}');exception when raise_exception then rejected:=true;end;assert rejected,'Review replacement needs consent';
 rejected:=false;begin perform plant_loft_tool('get_request','{"quote_code":"PL-unknown-private-code","customer_action":"received","confirmed":true}');exception when raise_exception then rejected:=true;end;
 -- Existing lookup may safely return found:false; neither outcome may mutate a request.
 assert (select count(*) from plant_loft_lifecycle_audit where request_id=rid and action='received')=1,'Private lookup and repeated receipt do not duplicate writes';
 q:=plant_loft_tool('prepare_quote','{"session_id":"lifecycle-rental-001","kind":"RENTAL","transport":"BUSINESS_DELIVERY","start_at":"2026-11-01T15:00:00+01:00","end_at":"2026-11-01T20:00:00+01:00","setup":false,"items":[{"category":"GOLDEN_PALM","quantity":10}],"transport_confirmed":true,"event_logistics":{"venue_access_at":"2026-11-01T13:00:00+01:00","setup_ready_at":"2026-11-01T14:30:00+01:00","onsite_contact":"Demo contact 08000000000"}}');
 code:=q->>'quote_code';r:=plant_loft_tool('confirm_request',jsonb_build_object('quote_code',code,'confirmed',true));rid:=(r->>'id')::uuid;
 perform plant_loft_owner('transport',jsonb_build_object('request_id',rid,'fee_kobo',100000,'owner_reference','lifecycle-rental-delivery','expected_version',0));
 perform plant_loft_tool('confirm_request',jsonb_build_object('quote_code',code,'confirmed',true,'transport_version',1,'confirmed_total_kobo',3600000));
 perform plant_loft_owner('confirm_transfer',jsonb_build_object('request_id',rid,'amount_kobo',3600000,'bank_reference','lifecycle-bank-rental','expected_version',1,'confirmed_by','Rahama test','funds_received',true));
 r:=plant_loft_tool('get_request',jsonb_build_object('quote_code',code,'customer_action','received','confirmed',true));assert r->>'status'='RENTAL_IN_USE','Receiving rental does not complete it';
 r:=plant_loft_owner('returned',jsonb_build_object('request_id',rid,'confirmed',true));assert r->>'status'='COMPLETED','Owner collection completes rental';
 q:=plant_loft_tool('prepare_quote','{"session_id":"lifecycle-pickup-001","kind":"SALE","transport":"SELF_PICKUP","items":[{"product_id":"plant-09","pot_id":"pot-19","quantity":1}],"transport_confirmed":true}');
 code:=q->>'quote_code';r:=plant_loft_tool('confirm_request',jsonb_build_object('quote_code',code,'confirmed',true));
 a:=plant_loft_prepare_payments((r->>'id')::uuid);assert jsonb_array_length(a)=2,'Demo pickup stock check is automatic';
 perform plant_loft_owner('approve_stock',jsonb_build_object('request_id',r->>'id','confirmed',true));
 a:=plant_loft_prepare_payments((r->>'id')::uuid);assert jsonb_array_length(a)=2,'Approved pickup can prepare payment';
end $$;
select 'PASS: quantity, payment claims, partial/stale/owner transfer, receipt replay, fulfilment, review validation/replay, rental return and pickup stock gates' result;
rollback;


begin;
do $$
declare q jsonb; r jsonb; a jsonb; x jsonb; rid uuid; code text; rejected boolean; before_count integer;
begin
 rejected:=false;begin perform plant_loft_tool('prepare_quote','{"session_id":"finish-explicit-001","kind":"SALE","transport":"SELF_PICKUP","items":[{"product_id":"plant-03","pot_id":"pot-19","quantity":1}]}');exception when raise_exception then rejected:=true;end;assert rejected,'Transport must be explicitly confirmed';
 rejected:=false;begin perform plant_loft_tool('prepare_quote','{"session_id":"finish-stock-001","kind":"SALE","transport":"SELF_PICKUP","transport_confirmed":true,"items":[{"product_id":"plant-03","pot_id":"pot-19","quantity":21}]}');exception when raise_exception then rejected:=true;end;assert rejected,'Demo stock quantity enforced';
 q:=plant_loft_tool('prepare_quote','{"session_id":"finish-pickup-001","kind":"SALE","transport":"SELF_PICKUP","transport_confirmed":true,"items":[{"product_id":"plant-03","pot_id":"pot-19","quantity":1}]}');code:=q->>'quote_code';r:=plant_loft_tool('confirm_request',jsonb_build_object('quote_code',code,'confirmed',true));rid:=(r->>'id')::uuid;
 assert r->'summary'->>'approval_source'='DEMO_CATALOGUE','No human stock approval';a:=plant_loft_prepare_payments(rid);assert jsonb_array_length(a)=2,'Pickup can pay after one confirmation';
 a:=plant_loft_tool('find_products','{"session_id":"finish-outdoors-001","placement":"EXPOSED_OUTDOOR","query":"Peace"}');assert a->>'total_matches'='0','No unverified fully exposed outdoor recommendations';
 assert (select data->'care'->>'pet_safety' like 'Toxic to cats and dogs%' from plant_loft_products where id='plant-03'),'Peace Lily toxicity consistent';
 rejected:=false;begin perform plant_loft_tool('prepare_quote','{"session_id":"finish-setup-001","kind":"RENTAL","transport":"SELF_PICKUP","transport_confirmed":true,"start_at":"2026-11-01T16:00:00+01:00","end_at":"2026-11-01T18:00:00+01:00","setup":true,"items":[{"category":"LADY_PALM","quantity":12}]}');exception when raise_exception then rejected:=true;end;assert rejected,'Setup logistics required';
 q:=plant_loft_tool('prepare_quote','{"session_id":"finish-rental-001","kind":"RENTAL","transport":"SELF_PICKUP","transport_confirmed":true,"start_at":"2026-11-01T16:00:00+01:00","end_at":"2026-11-01T18:00:00+01:00","setup":true,"event_logistics":{"venue_access_at":"2026-11-01T14:00:00+01:00","setup_ready_at":"2026-11-01T15:30:00+01:00","onsite_contact":"Demo 08000000000"},"items":[{"category":"LADY_PALM","quantity":12}]}');
 assert q->'summary'->'rental_terms'->>'notice_hours'='1','Terms in quote before save/payment';assert q->'summary'->'event_logistics'->>'onsite_contact'='Demo 08000000000','Setup instructions persisted';
 code:=q->>'quote_code';r:=plant_loft_tool('confirm_request',jsonb_build_object('quote_code',code,'confirmed',true));rid:=(r->>'id')::uuid;
 perform plant_loft_owner('confirm_transfer',jsonb_build_object('request_id',rid,'amount_kobo',6200000,'expected_version',0,'bank_reference','FINISH-RENTAL-RECEIPT','confirmed_by','Demo owner','funds_received',true));
 perform plant_loft_owner('delivered',jsonb_build_object('request_id',rid,'confirmed',true));
 a:=jsonb_build_object('quote_code',code,'customer_action','report_return','handover_description','two hours ago','received_by','Demo driver','issue_details','I handed the plants to your driver two hours ago');
 r:=plant_loft_tool('get_request',a);assert r->>'return_reported'='true','Return report recorded';assert r->>'collection_confirmed'='false','Claim is not confirmed return';assert r->>'status'='RENTAL_IN_USE','Claim does not close rental';
 perform plant_loft_tool('get_request',a);assert (select count(*) from plant_loft_followups where request_id=rid and kind='RETURN_CLAIM')=1,'Return report replay one case';
 perform plant_loft_owner('returned',jsonb_build_object('request_id',rid,'confirmed',true));
 r:=plant_loft_tool('get_request',jsonb_build_object('quote_code',code));assert r->>'collection_confirmed'='true','Owner collection completes';assert (select status from plant_loft_followups where request_id=rid and kind='RETURN_CLAIM')='RESOLVED','Collection resolves return report';
 r:=plant_loft_tool('get_request',jsonb_build_object('quote_code',code,'customer_action','review','product_rating',4,'service_rating',3,'service_feedback','Slow response'));
 assert (select count(*) from plant_loft_followups where request_id=rid and kind='LOW_RATING')=1,'Low service rating queued';
 perform plant_loft_tool('get_request',jsonb_build_object('quote_code',code,'customer_action','report_issue','issue_details','A pot was chipped'));
 assert (select count(*) from plant_loft_followups where request_id=rid and kind='COMPLAINT')=1,'Complaint queued';
 assert not has_table_privilege('anon','public.plant_loft_followups','SELECT'),'No anonymous queue access';
end $$;
select 'PASS: explicit transport, demo stock, pickup payment, exposed outdoor rejection, toxicity, setup/terms, return claim/replay, owner collection, low-rating and complaint queues' result;
rollback;

select 'PASS: all eight current SQL acceptance suites' result;
