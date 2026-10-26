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
