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
