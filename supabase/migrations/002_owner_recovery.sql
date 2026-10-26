-- Incremental demo migration: capability-code recovery and owner-only transport quotes.
begin;
alter table public.plant_loft_quotes add column tracking_code text not null default
 ('PL-'||translate(rtrim(encode(uuid_send(gen_random_uuid()),'base64'),'='),'+/','-_'));
alter table public.plant_loft_quotes add constraint plant_loft_tracking_code_key unique(tracking_code);
create or replace function public.plant_loft_tool(action text, payload jsonb)
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
   if not found then return jsonb_build_object('found',false); end if;
   select * into r from plant_loft_requests where quote_id=q.id;
  else
   select * into q from plant_loft_quotes where id=(payload->>'quote_id')::uuid and session_id=sid;
   select * into r from plant_loft_requests where session_id=sid and quote_id=q.id;
  end if;
  if not found then return jsonb_build_object('found',false); end if;
  return (to_jsonb(r)-'session_id')||jsonb_build_object('quote_code',q.tracking_code);
 else raise exception 'Unsupported action'; end if;
end $$;

create table public.plant_loft_transport_audit (
 id bigint generated always as identity primary key,
 request_id uuid not null references public.plant_loft_requests(id),
 version integer not null,fee_kobo bigint not null,owner_reference text not null,
 created_at timestamptz not null default now(),unique(request_id,version)
);
alter table public.plant_loft_transport_audit enable row level security;
revoke all on public.plant_loft_transport_audit from anon,authenticated;
grant all on public.plant_loft_transport_audit to service_role;
grant usage,select on sequence public.plant_loft_transport_audit_id_seq to service_role;
create or replace function public.plant_loft_owner(action text, payload jsonb)
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare r plant_loft_requests%rowtype; fee bigint; v integer; counts jsonb; reqs jsonb; events jsonb;
begin
 if action='snapshot' then
  select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at),'[]') into reqs
   from (select id,quote_id,kind,status,summary,created_at from plant_loft_requests) t;
  select coalesce(jsonb_agg(to_jsonb(t) order by t.id),'[]') into events
   from (select id,stage,kind,quote_id,request_id,created_at from plant_loft_events) t;
  select jsonb_object_agg(stage,n) into counts from
   (select stage,count(*) n from plant_loft_events group by stage) t;
  return jsonb_build_object('demo',true,'generated_at',now(),'revision',coalesce((select max(id) from plant_loft_events),0),
   'counts',counts,'requests',reqs,'events',events);
 elsif action='transport' then
  if payload->>'request_id' is null then raise exception 'Request ID required'; end if;
  fee:=(payload->>'fee_kobo')::bigint;
  if fee is null or fee<0 or fee>1000000000 then raise exception 'Fee must be 0 to 10,000,000 NGN'; end if;
  if length(coalesce(payload->>'owner_reference','')) not between 3 and 100 then raise exception 'Owner quote reference required'; end if;
  select * into r from plant_loft_requests where id=(payload->>'request_id')::uuid for update;
  if not found then raise exception 'Request not found'; end if;
  if r.summary->>'transport'<>'BUSINESS_DELIVERY' then raise exception 'Request does not require business transport'; end if;
  if r.summary->>'payment_status'<>'UNPAID' then raise exception 'Paid request needs manual review'; end if;
  if (r.summary->>'transport_fee_kobo')::bigint=fee and r.summary->>'owner_quote_reference'=payload->>'owner_reference' then
   return to_jsonb(r)-'session_id';
  end if;
  v:=coalesce((r.summary->>'transport_version')::integer,0);
  if coalesce((payload->>'expected_version')::integer,-1)<>v then raise exception 'Request changed; refresh before quoting'; end if;
  update plant_loft_requests set status='AWAITING_CUSTOMER_CONFIRMATION',summary=summary||jsonb_build_object(
   'transport_fee_kobo',fee,'transport_status','QUOTED_ROUND_TRIP','transport_version',v+1,
   'transport_accepted',false,'owner_quote_reference',payload->>'owner_reference','transport_quoted_at',now(),
   'final_total_kobo',(summary->>'known_subtotal_kobo')::bigint+fee)
   where id=r.id returning * into r;
  insert into plant_loft_transport_audit(request_id,version,fee_kobo,owner_reference)
   values(r.id,v+1,fee,payload->>'owner_reference');
  insert into plant_loft_events(session_id,stage,kind,quote_id,request_id)
   values(r.session_id,'transport_quoted',r.kind,r.quote_id,r.id);
  return to_jsonb(r)-'session_id';
 else raise exception 'Unknown owner action'; end if;
end $$;
revoke all on function public.plant_loft_owner(text,jsonb) from public,anon,authenticated;
grant execute on function public.plant_loft_owner(text,jsonb) to service_role;

commit;
