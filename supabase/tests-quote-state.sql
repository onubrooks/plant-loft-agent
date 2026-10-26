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
