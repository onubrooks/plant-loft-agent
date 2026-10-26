-- Incremental customer experience upgrade. Apply once after 003.
begin;
-- Abort if this is not the expected tiny synthetic catalogue. No unrestricted UPDATE.
do $$ begin
 if (select count(*) from public.plant_loft_products where id in ('plant-01','plant-03','plant-07','plant-09','plant-15'))<>5
 then raise exception 'Expected five scoped catalogue records'; end if;
end $$;
-- Display references are never access credentials; the private capability stays unchanged.
create sequence public.plant_loft_display_reference_seq start 10000 maxvalue 99999 no cycle;
revoke all on sequence public.plant_loft_display_reference_seq from public, anon, authenticated;
alter table public.plant_loft_quotes add column customer_reference text not null
 default nextval('public.plant_loft_display_reference_seq')::text unique
 check(customer_reference ~ '^[0-9]{5}$');
alter function public.plant_loft_tool(text,jsonb) rename to plant_loft_tool_v3;
revoke all on function public.plant_loft_tool_v3(text,jsonb) from public, anon, authenticated;
grant execute on function public.plant_loft_tool_v3(text,jsonb) to service_role;
grant usage, select on sequence public.plant_loft_display_reference_seq to service_role;
update public.plant_loft_products set data=data||'{"care": {"light": "Bright indirect light; also tolerates lower light.", "watering": "Let the compost dry between waterings; avoid standing water.", "difficulty": "Easy; drought tolerant.", "pet_safety": "Toxic to cats and dogs if chewed; keep out of reach.", "sources": ["https://www.rhs.org.uk/plants/sansevieria/growing-guide", "https://www.aspca.org/pet-care/aspca-poison-control/toxic-and-non-toxic-plants/snake-plant"], "review_status": "REFERENCE_CHECKED_OWNER_SIGNOFF_PENDING", "checked_on": "2026-10-24"}, "suitability_notes": "Bright indirect light; also tolerates lower light. Let the compost dry between waterings; avoid standing water."}'::jsonb where id='plant-01';
update public.plant_loft_products set data=data||'{"care": {"light": "Bright indirect or filtered light; avoid harsh direct sun.", "watering": "Water moderately, allowing the surface to dry; drain excess water.", "difficulty": "Easy with regular moisture checks.", "pet_safety": "Not suitable where pets may chew it; ingestion can irritate the mouth.", "sources": ["https://www.rhs.org.uk/plants/peace-lilies/how-to-grow-peace-lilies", "https://www.aspca.org/news/houseplant-safe-your-pets"], "review_status": "REFERENCE_CHECKED_OWNER_SIGNOFF_PENDING", "checked_on": "2026-10-24"}, "suitability_notes": "Bright indirect or filtered light; avoid harsh direct sun. Water moderately, allowing the surface to dry; drain excess water."}'::jsonb where id='plant-03';
update public.plant_loft_products set data=data||'{"care": {"light": "Bright indirect light; tolerates some shade.", "watering": "Let the top 2 cm of compost dry before watering; avoid waterlogging.", "difficulty": "Easy; adaptable trailing plant.", "pet_safety": "Keep away from children and pets; toxic if ingested.", "sources": ["https://www.rhs.org.uk/plants/epipremnum"], "review_status": "REFERENCE_CHECKED_OWNER_SIGNOFF_PENDING", "checked_on": "2026-10-24"}, "suitability_notes": "Bright indirect light; tolerates some shade. Let the top 2 cm of compost dry before watering; avoid waterlogging."}'::jsonb where id='plant-07';
update public.plant_loft_products set data=data||'{"care": {"light": "Bright indirect light.", "watering": "Keep moist but well drained; adjust watering to conditions, not a fixed schedule.", "difficulty": "Moderate; check soil moisture regularly.", "pet_safety": "Do not treat as pet-safe; keep away from pets that chew plants.", "sources": ["https://www.rhs.org.uk/plants/17899/syngonium-podophyllum/details", "https://www.msdvetmanual.com/multimedia/image/arrowhead-vine-syngonium-spp"], "review_status": "REFERENCE_CHECKED_OWNER_SIGNOFF_PENDING", "checked_on": "2026-10-24"}, "suitability_notes": "Bright indirect light. Keep moist but well drained; adjust watering to conditions, not a fixed schedule."}'::jsonb where id='plant-09';
update public.plant_loft_products set data=data||'{"care": {"light": "Bright indirect light; avoid strong direct sun.", "watering": "Let the top 2 cm of compost dry before watering; avoid waterlogging.", "difficulty": "Easy; brighter light helps preserve variegation.", "pet_safety": "Keep away from children and pets; toxic if ingested.", "sources": ["https://www.rhs.org.uk/plants/epipremnum"], "review_status": "REFERENCE_CHECKED_OWNER_SIGNOFF_PENDING", "checked_on": "2026-10-24"}, "suitability_notes": "Bright indirect light; avoid strong direct sun. Let the top 2 cm of compost dry before watering; avoid waterlogging."}'::jsonb where id='plant-15';
create function public.plant_loft_tool(action text, payload jsonb)
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare
 result jsonb; sid text:=payload->>'session_id'; n integer; lim integer; off integer;
 matches jsonb; q public.plant_loft_quotes%rowtype; query_text text;
begin
 if action='find_products' then
  if sid is null or length(sid) not between 8 and 100 then raise exception 'A synthetic session_id of 8-100 characters is required'; end if;
  lim:=coalesce((payload->>'limit')::integer,3); off:=coalesce((payload->>'offset')::integer,0);
  if lim not between 1 and 5 or off not between 0 and 1000 then raise exception 'Use limit 1-5 and offset 0-1000'; end if;
  if payload->>'budget_kobo' is not null and (payload->>'budget_kobo')::bigint<0 then raise exception 'Budget must be nonnegative'; end if;
  query_text:=coalesce(payload->>'query','');
  if lower(query_text)='singonium' then query_text:='syngonium'; end if;
  select coalesce(jsonb_agg(data order by (data->>'sale_price_kobo')::bigint,id),'[]') into matches
   from public.plant_loft_products where coalesce((data->>'recommendation_enabled')::boolean,false)
    and (query_text='' or data->>'name' ilike '%'||query_text||'%')
    and (coalesce(payload->>'product_kind','')='' or data->>'kind'=payload->>'product_kind')
    and (coalesce(payload->>'size','')='' or data->>'size'=payload->>'size')
    and (payload->>'budget_kobo' is null or (data->>'sale_price_kobo')::bigint<=(payload->>'budget_kobo')::bigint);
  n:=jsonb_array_length(matches);
  select coalesce(jsonb_agg(jsonb_build_object(
   'id',v->>'id','name',v->>'name','kind',v->>'kind','size',replace(v->>'size',' (demo assumption)',''),
   'sale_price_kobo',v->'sale_price_kobo','currency','NGN','image_path',v->>'image_path',
   'image_notes',v->>'image_notes','close_up',v->'close_up','care',v->'care',
   'availability','OWNER_CHECK_REQUIRED','compatibility',case when v->>'kind'='plant' then 'Medium pot required by this catalogue configuration' else null end
  ) order by ord),'[]') into result from jsonb_array_elements(matches) with ordinality a(v,ord)
   where ord>off and ord<=off+lim;
  insert into public.plant_loft_events(session_id,stage,kind) values(sid,'catalogue_viewed',payload->>'kind');
  return jsonb_build_object('products',result,'total_matches',n,'returned_count',jsonb_array_length(result),
   'has_more',off+lim<n,'next_offset',case when off+lim<n then off+lim else null end,
   'budget_basis','Plant or pot alone; pot and delivery are separate.','result_complete',true);
 end if;
 -- No short-reference lookup: five digits must never replace a private capability.
 result:=public.plant_loft_tool_v3(action,payload);
 if result->>'quote_id' is not null then select * into q from public.plant_loft_quotes where id=(result->>'quote_id')::uuid;
 elsif result->>'quote_code' is not null then select * into q from public.plant_loft_quotes where tracking_code=result->>'quote_code'; end if;
 if q.id is not null then
  if action='prepare_quote' and payload ? 'delivery_details' then
   if jsonb_typeof(payload->'delivery_details')<>'object' or length((payload->'delivery_details')::text)>1200 then raise exception 'Invalid delivery details'; end if;
   update public.plant_loft_quotes set summary=summary||jsonb_build_object('delivery_details',payload->'delivery_details') where id=q.id returning * into q;
   result:=result||jsonb_build_object('summary',q.summary);
  end if;
  result:=result||jsonb_build_object('customer_reference',q.customer_reference);
 end if;
 return result;
end $$;
revoke all on function public.plant_loft_tool(text,jsonb) from public, anon, authenticated;
grant execute on function public.plant_loft_tool(text,jsonb) to service_role;
commit;
