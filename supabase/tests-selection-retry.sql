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
