-- Function definition only; existing records and capabilities are unchanged.
begin;
create or replace function public.plant_loft_tool(action text, payload jsonb)
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
 -- Resource existence and request persistence are distinct. Do not make the model infer them.
 if q.id is not null then
  result:=result||jsonb_build_object('quote_persisted',true,'identifiers_verified',true,'do_not_requote',true);
  if action='prepare_quote' or result->>'state'='QUOTE_AWAITING_SAVE' then
   result:=result||jsonb_build_object('found',true,'request_saved',false,
    'next_action','ON_CUSTOMER_YES_CALL_CONFIRM_REQUEST_WITH_THIS_EXACT_PAYLOAD',
    'save_payload',jsonb_build_object('payload',jsonb_build_object('quote_code',q.tracking_code,'confirmed',true)));
  else
   result:=result||jsonb_build_object('found',true,'request_saved',true,
    'next_action',case when result->>'confirmation_required'='true' then 'ACCEPT_LATEST_DELIVERY_VERSION_AND_TOTAL' else 'REPLY_WITH_THIS_SAVED_REFERENCE_AND_NEXT_STEP' end);
  end if;
 end if;
 return result;
end $$;
revoke all on function public.plant_loft_tool(text,jsonb) from public, anon, authenticated;
grant execute on function public.plant_loft_tool(text,jsonb) to service_role;
commit;
