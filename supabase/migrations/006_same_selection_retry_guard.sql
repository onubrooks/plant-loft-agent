-- Clarify quote existence separately from request persistence. No change to consent or pricing.
begin;
create or replace function public.plant_loft_tool_v3(action text, payload jsonb)
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare
 sid text := payload->>'session_id'; mode text := payload->>'kind';
 line jsonb; product jsonb; pot jsonb; result jsonb; q plant_loft_quotes%rowtype;
 r plant_loft_requests%rowtype; lines jsonb := '[]'; qty integer; total bigint:=0;
 big integer:=0; small integer:=0; unit bigint; periods integer:=1;
 start_time timestamptz; end_time timestamptz; hours numeric; setup bigint:=0;
 transport text; subtotal bigint; review boolean:=false;
begin
 if not (action in ('confirm_request','get_request') and payload->>'quote_code' is not null) and (sid is null or length(sid)<8 or length(sid)>100) then
  raise exception 'A synthetic session_id of 8-100 characters is required';
 end if;
 if action='find_products' then
  select coalesce(jsonb_agg(data order by id),'[]'::jsonb) into result
  from plant_loft_products where
   coalesce((data->>'recommendation_enabled')::boolean,false)
   and (coalesce(payload->>'query','')='' or data->>'name' ilike '%'||(payload->>'query')||'%')
   and (coalesce(payload->>'product_kind','')='' or data->>'kind'=payload->>'product_kind')
   and (payload->>'budget_kobo' is null or (data->>'sale_price_kobo')::bigint <= (payload->>'budget_kobo')::bigint);
  insert into plant_loft_events(session_id,stage,kind) values(sid,'catalogue_viewed',mode);
  return jsonb_build_object('demo',true,'products',result,'note','Typical photos; sizes and sale prices are fictional. No stock reservation.');
 elsif action='prepare_quote' then
  if mode not in ('SALE','RENTAL') or mode is null then raise exception 'kind must be SALE or RENTAL'; end if;
  if jsonb_typeof(payload->'items') is distinct from 'array' then raise exception 'items must be an array'; end if;
  if jsonb_array_length(payload->'items') not between 1 and 20 then raise exception 'Provide 1-20 lines'; end if;
  transport:=payload->>'transport';
  if transport not in ('SELF_PICKUP','BUSINESS_DELIVERY') or transport is null then raise exception 'Choose transport'; end if;
  if mode='RENTAL' then
   start_time:=(payload->>'start_at')::timestamptz; end_time:=(payload->>'end_at')::timestamptz;
   if start_time is null or end_time is null or end_time<=start_time then raise exception 'Valid start_at and end_at required'; end if;
   hours:=extract(epoch from (end_time-start_time))/3600;
   if hours>24*7 then raise exception 'Demo accepts at most seven days; request owner review'; end if;
   if mod(hours,24)<>0 then raise exception 'Partial 24-hour periods need owner review; no automatic quote'; end if;
   periods:=(hours/24)::integer;
   if coalesce((payload->>'setup')::boolean,false) then setup:=2000000; end if;
  end if;
  for line in select value from jsonb_array_elements(payload->'items') loop
   qty:=(line->>'quantity')::integer;
   if qty is null or qty not between 1 and 40 then raise exception 'quantity must be 1-40'; end if;
   if mode='SALE' then
    select data into product from plant_loft_products where id=line->>'product_id';
    select data into pot from plant_loft_products where id=line->>'pot_id';
    if product is null or product->>'kind'<>'plant' or pot is null or pot->>'kind'<>'pot' then raise exception 'Unknown plant or pot'; end if;
    if not coalesce((product->>'recommendation_enabled')::boolean,false) then raise exception 'Product image needs owner review'; end if;
    if pot->>'size'<>'Medium' then raise exception 'Demo plant configuration supports medium pots only'; end if;
    unit:=(product->>'sale_price_kobo')::bigint+(pot->>'sale_price_kobo')::bigint;
    total:=total+unit*qty;
    lines:=lines||jsonb_build_array(jsonb_build_object('product',product->>'name','pot',pot->>'name','quantity',qty,'unit_kobo',unit,'line_kobo',unit*qty));
   else
    if line->>'category' in ('GOLDEN_PALM','LADY_PALM') then big:=big+qty;
    elsif line->>'category'='SMALL_PLANT' then small:=small+qty;
    else raise exception 'Unknown rental category'; end if;
    lines:=lines||jsonb_build_array(line);
   end if;
  end loop;
  if mode='RENTAL' then
   if big+small>60 then raise exception 'Large request needs owner review'; end if;
   unit:=case when big>=10 then 350000 else 450000 end;
   total:=(big*unit+small*200000)*periods;
   review:=true;
  end if;
  subtotal:=total+setup;
  result:=jsonb_build_object('demo',true,'currency','NGN','money_unit','KOBO','items',lines,
   'rental_periods',case when mode='RENTAL' then periods else null end,
   'large_palm_unit_kobo',case when mode='RENTAL' then unit else null end,
   'goods_or_rental_kobo',total,'setup_kobo',setup,'known_subtotal_kobo',subtotal,
   'transport',transport,'transport_fee_kobo',case when transport='SELF_PICKUP' then 0 else null end,
   'transport_status',case when transport='SELF_PICKUP' then 'NOT_REQUIRED' else 'PENDING_ROUND_TRIP_QUOTE' end,
   'final_total_kobo',case when transport='SELF_PICKUP' then subtotal else null end,
   'start_at',start_time,'end_at',end_time,'owner_review',review,
   'payment_due','BEFORE_DELIVERY','payment_status','UNPAID','policy_version','demo-v1');
  if payload ? 'delivery_details' then result:=result||jsonb_build_object('delivery_details',payload->'delivery_details'); end if;
  -- Serialize equivalent draft creation within the same synthetic session.
  -- This is a retry safeguard, not trusted channel identity or cross-customer matching.
  perform pg_advisory_xact_lock(hashtextextended(sid||'|'||mode,0));
  if not coalesce((payload->>'new_order')::boolean,false) then
   select * into q from public.plant_loft_quotes existing
    where existing.session_id=sid and existing.kind=mode and existing.summary=result
     and existing.expires_at>now() and existing.created_at>=now()-interval '30 minutes'
    order by exists(select 1 from public.plant_loft_requests saved where saved.quote_id=existing.id) desc,
     existing.created_at asc limit 1 for update;
   if found then
    return jsonb_build_object('quote_id',q.id,'quote_code',q.tracking_code,'expires_at',q.expires_at,
     'summary',q.summary,'draft_reused',true);
   end if;
  end if;
  insert into plant_loft_quotes(session_id,kind,summary) values(sid,mode,result) returning * into q;
  insert into plant_loft_events(session_id,stage,kind,quote_id) values(sid,'quoted',mode,q.id);
  return jsonb_build_object('quote_id',q.id,'quote_code',q.tracking_code,'expires_at',q.expires_at,'summary',result);
 elsif action='confirm_request' then
  if payload->>'quote_code' is not null then
   select * into q from plant_loft_quotes where tracking_code=payload->>'quote_code' for update;
  else
   select * into q from plant_loft_quotes where id=(payload->>'quote_id')::uuid and session_id=sid for update;
  end if;
  sid:=q.session_id;
  if not found then raise exception 'Quote not found for session'; end if;
  select * into r from plant_loft_requests where quote_id=q.id for update;
  if found then
   if r.status='AWAITING_CUSTOMER_CONFIRMATION' and payload->'confirmed'='true'::jsonb then
    if payload->>'transport_version' is null or payload->>'confirmed_total_kobo' is null then
     return (to_jsonb(r)-'session_id')||jsonb_build_object('quote_code',q.tracking_code,'confirmation_required',true);
    end if;
    if (payload->>'transport_version')::integer<>(r.summary->>'transport_version')::integer
      or (payload->>'confirmed_total_kobo')::bigint<>(r.summary->>'final_total_kobo')::bigint then
     raise exception 'Transport quote changed; retrieve latest total and ask customer to confirm';
    end if;
    update plant_loft_requests set summary=summary||'{"transport_accepted":true}'::jsonb,
     status=case when kind='RENTAL' then 'AWAITING_OWNER_REVIEW' else 'AWAITING_PAYMENT' end
     where id=r.id returning * into r;
    insert into plant_loft_events(session_id,stage,kind,quote_id,request_id)
     values(sid,'transport_accepted',r.kind,q.id,r.id);
   end if;
   return (to_jsonb(r)-'session_id')||jsonb_build_object('quote_code',q.tracking_code);
  end if;
  if q.expires_at<now() then raise exception 'Quote expired; refresh and confirm again'; end if;
  if payload->'confirmed' is distinct from 'true'::jsonb then raise exception 'Explicit confirmation required'; end if;
  insert into plant_loft_requests(quote_id,session_id,kind,status,summary)
  values(q.id,sid,q.kind,case when q.kind='RENTAL' or q.summary->>'transport'='BUSINESS_DELIVERY' then 'AWAITING_OWNER_REVIEW' else 'AWAITING_PAYMENT' end,q.summary)
  returning * into r;
  insert into plant_loft_events(session_id,stage,kind,quote_id,request_id) values(sid,'request_confirmed',q.kind,q.id,r.id);
  return (to_jsonb(r)-'session_id')||jsonb_build_object('quote_code',q.tracking_code);
 elsif action='get_request' then
  if payload->>'quote_code' is not null then
   select * into q from plant_loft_quotes where tracking_code=payload->>'quote_code';
  else
   select * into q from plant_loft_quotes where id=(payload->>'quote_id')::uuid and session_id=sid;
  end if;
  if not found then
   return jsonb_build_object('found',false,'quote_found',false,'state','QUOTE_NOT_FOUND',
    'next_action','CHECK_CODE_OR_HAND_OFF','note','Quote not found. Do not invent a replacement code.');
  end if;
  select * into r from plant_loft_requests where quote_id=q.id;
  if not found then
   return jsonb_build_object('found',false,'quote_found',true,'state','QUOTE_AWAITING_SAVE',
    'quote_id',q.id,'quote_code',q.tracking_code,'summary',q.summary,'expires_at',q.expires_at,
    'next_action','CONFIRM_EXISTING_QUOTE_IF_CUSTOMER_ALREADY_CONFIRMED',
    'note','This quote exists. No request is saved yet. If the customer already said yes/save, call confirm_request with this exact quote_code and confirmed:true. Do not create another quote or ask again for unchanged terms.');
  end if;
  return (to_jsonb(r)-'session_id')||jsonb_build_object('found',true,'quote_found',true,
   'state','REQUEST_SAVED','quote_code',q.tracking_code,'next_action','RETURN_EXISTING_REQUEST');
 else raise exception 'Unsupported action'; end if;
end $$;
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
 if action='prepare_quote' and payload ? 'delivery_details' then
  if jsonb_typeof(payload->'delivery_details')<>'object' or length((payload->'delivery_details')::text)>1200 then raise exception 'Invalid delivery details'; end if;
 end if;
 result:=public.plant_loft_tool_v3(action,payload);
 if result->>'quote_id' is not null then select * into q from public.plant_loft_quotes where id=(result->>'quote_id')::uuid;
 elsif result->>'quote_code' is not null then select * into q from public.plant_loft_quotes where tracking_code=result->>'quote_code'; end if;
 if q.id is not null then
  if action='prepare_quote' and exists(select 1 from public.plant_loft_requests saved where saved.quote_id=q.id) then
   result:=result||public.plant_loft_tool_v3('get_request',jsonb_build_object('quote_code',q.tracking_code));
  end if;

  result:=result||jsonb_build_object('customer_reference',q.customer_reference);
 end if;
 -- Resource existence and request persistence are distinct. Do not make the model infer them.
 if q.id is not null then
  result:=result||jsonb_build_object('quote_persisted',true,'identifiers_verified',true,'do_not_requote',true);
  if (action='prepare_quote' and result->>'state' is distinct from 'REQUEST_SAVED') or result->>'state'='QUOTE_AWAITING_SAVE' then
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
