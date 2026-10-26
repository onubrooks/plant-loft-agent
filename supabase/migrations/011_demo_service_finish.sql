begin;
alter function public.plant_loft_tool(text,jsonb) rename to plant_loft_tool_v10;
alter function public.plant_loft_owner(text,jsonb) rename to plant_loft_owner_v10;
create table public.plant_loft_demo_stock(id text primary key, quantity integer not null check(quantity>=0));
insert into public.plant_loft_demo_stock select id,20 from public.plant_loft_products;
insert into public.plant_loft_demo_stock values('GOLDEN_PALM',20),('LADY_PALM',20),('SMALL_PLANT',20);
alter table public.plant_loft_demo_stock enable row level security;
revoke all on public.plant_loft_demo_stock from public,anon,authenticated;
grant all on public.plant_loft_demo_stock to service_role;
create table public.plant_loft_followups (
 id uuid primary key default gen_random_uuid(), request_id uuid not null references public.plant_loft_requests(id),
 kind text not null check(kind in ('RETURN_CLAIM','LOW_RATING','COMPLAINT')), priority text not null default 'HIGH',
 status text not null default 'OPEN', details jsonb not null, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 unique(request_id,kind)
);
insert into public.plant_loft_followups(request_id,kind,details) select request_id,'LOW_RATING',to_jsonb(v)-'request_id' from public.plant_loft_reviews v where product_rating<=3 or service_rating<=3;
alter table public.plant_loft_followups enable row level security;
revoke all on public.plant_loft_followups from public,anon,authenticated;
grant all on public.plant_loft_followups to service_role;
create function public.plant_loft_followup(rid uuid, category text, info jsonb)
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare result jsonb;
begin
 if length(info::text)>4000 then raise exception 'Follow-up details too long'; end if;
 insert into public.plant_loft_followups(request_id,kind,details) values(rid,category,info)
 on conflict(request_id,kind) do update set details=plant_loft_followups.details||excluded.details,updated_at=now();
 select to_jsonb(f) into result from public.plant_loft_followups f where request_id=rid and kind=category;
 return result;
end $$;
create function public.plant_loft_check_demo_stock(kind text, items jsonb)
returns void language plpgsql security invoker set search_path=public,pg_temp as $$
declare line record; available integer; item_id text;
begin
 for line in select coalesce(x->>'product_id',x->>'product',x->>'category') item,sum((x->>'quantity')::integer) quantity from jsonb_array_elements(items) x group by 1 loop
  item_id:=line.item;
  if kind='SALE' and not exists(select 1 from public.plant_loft_demo_stock where id=item_id) then
   select id into item_id from public.plant_loft_products where data->>'name'=line.item;
  end if;
  select quantity into available from public.plant_loft_demo_stock where id=item_id;
  if available is null or line.quantity is null or line.quantity<1 or line.quantity>available then raise exception 'Requested quantity is unavailable in the current catalogue; choose fewer or another plant'; end if;
 end loop;
 if kind='SALE' then
  for line in select coalesce(x->>'pot_id',x->>'pot') item,sum((x->>'quantity')::integer) quantity from jsonb_array_elements(items) x group by 1 loop
   item_id:=line.item;
   if not exists(select 1 from public.plant_loft_demo_stock where id=item_id) then select id into item_id from public.plant_loft_products where data->>'name'=line.item;end if;
   select quantity into available from public.plant_loft_demo_stock where id=item_id;
   if available is null or line.quantity>available then raise exception 'Requested pot quantity is unavailable';end if;
  end loop;
 end if;
end $$;
create function public.plant_loft_tool(action text,payload jsonb)
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare result jsonb; q public.plant_loft_quotes%rowtype; r public.plant_loft_requests%rowtype; op text:=payload->>'customer_action'; f jsonb; rev jsonb; logistics jsonb; ready timestamptz; access_at timestamptz; kept_op boolean;
begin
 if action='prepare_quote' then
  if payload->>'transport_confirmed' is distinct from 'true' then raise exception 'Ask customer to choose pickup or delivery explicitly before quoting'; end if;
  perform public.plant_loft_check_demo_stock(payload->>'kind',payload->'items');
  if payload->>'kind'='RENTAL' and coalesce((payload->>'setup')::boolean,false) then
   logistics:=payload->'event_logistics';
   if jsonb_typeof(logistics) is distinct from 'object' then raise exception 'Setup completion time, venue access time and onsite contact are required'; end if;
   ready:=(logistics->>'setup_ready_at')::timestamptz; access_at:=(logistics->>'venue_access_at')::timestamptz;
   if ready is null or access_at is null or ready>(payload->>'start_at')::timestamptz or access_at>=ready or length(trim(coalesce(logistics->>'onsite_contact','')))<2 then raise exception 'Confirm venue access before setup completion, completion by event start, and onsite contact'; end if;
  elsif payload ? 'event_logistics' then logistics:=payload->'event_logistics';end if;
 end if;
 if action='find_products' and payload->>'placement'='EXPOSED_OUTDOOR' then
  return jsonb_build_object('products','[]'::jsonb,'total_matches',0,'returned_count',0,'has_more',false,'result_complete',true,'placement_note','No catalogue item is verified for a fully weather-exposed outdoor site. Ask about a sheltered alternative; do not silently switch to indoor recommendations.');
 end if;
 kept_op:=op in ('report_return','report_issue');
 result:=public.plant_loft_tool_v10(action,case when kept_op then payload-'customer_action' else payload end);
 if action='find_products' then
  select coalesce(jsonb_agg(p||jsonb_build_object('availability',case when s.quantity>0 then 'AVAILABLE' else 'UNAVAILABLE' end,
   'available_quantity',coalesce(s.quantity,0),'placement_profile',jsonb_build_object('indoor',true,'sheltered_outdoor','CONDITIONAL_SHADE_DRAINAGE_AND_WEATHER_PROTECTION','exposed_outdoor_verified',false))),'[]') into f
   from jsonb_array_elements(result->'products') p left join public.plant_loft_demo_stock s on s.id=p->>'id';
  return result||jsonb_build_object('products',f,'stock_basis','CONFIGURED_DEMO_SNAPSHOT_NOT_A_DATE_RESERVATION');
 end if;
 if action='prepare_quote' then
  select * into q from public.plant_loft_quotes where tracking_code=result->>'quote_code';
  if q.id is not null and result->>'request_saved' is distinct from 'true' then
   update public.plant_loft_quotes set summary=summary||jsonb_build_object('availability_status','AVAILABLE','stock_basis','DEMO_SNAPSHOT_NO_RESERVATION','transport_confirmed',true)
    ||case when q.kind='RENTAL' then jsonb_build_object('rental_terms',jsonb_build_object('billing_hours',24,'notice_hours',1,'damage','Full replacement cost of affected potted plant','extensions','Same rate per additional started 24-hour period; collection-time changes require checking','driver_delay_auto_charge',false)) else '{}'::jsonb end
    ||case when logistics is not null then jsonb_build_object('event_logistics',logistics) else '{}'::jsonb end where id=q.id returning * into q;
   result:=result||jsonb_build_object('summary',q.summary);
  end if;
 end if;
 if action in ('confirm_request','get_request') and result->>'id' is not null then
  select * into r from public.plant_loft_requests where id=(result->>'id')::uuid for update;
  if r.summary->>'payment_status'='UNPAID' then
   perform public.plant_loft_check_demo_stock(r.kind,r.summary->'items');
   update public.plant_loft_requests set summary=summary||jsonb_build_object('owner_approved',true,'approval_source','DEMO_CATALOGUE','availability_status','AVAILABLE',
     'transport_version',coalesce((summary->>'transport_version')::integer,0))
     ||case when summary->>'transport'='SELF_PICKUP' then '{"transport_accepted":true}'::jsonb else '{}'::jsonb end,
     status=case when summary->>'transport'='SELF_PICKUP' then 'AWAITING_PAYMENT' else status end where id=r.id;
  end if;
  if kept_op then
   if action<>'get_request' or payload->>'quote_code' is null then raise exception 'Use the saved private code for a customer follow-up'; end if;
   if op='report_return' then
    if r.kind<>'RENTAL' then raise exception 'Return report is for rentals'; end if;
    if r.status<>'COMPLETED' then
     f:=public.plant_loft_followup(r.id,'RETURN_CLAIM',jsonb_strip_nulls(jsonb_build_object('handover_description',payload->>'handover_description','received_by',payload->>'received_by','reported_handover_at',payload->>'reported_handover_at','customer_message',payload->>'issue_details')));
    end if;
   else f:=public.plant_loft_followup(r.id,'COMPLAINT',jsonb_build_object('customer_message',coalesce(payload->>'issue_details','Customer requests follow-up')));end if;
  end if;
  if op='review' then
   select to_jsonb(v) into rev from public.plant_loft_reviews v where request_id=r.id;
   if (rev->>'product_rating')::integer<=3 or (rev->>'service_rating')::integer<=3 then f:=public.plant_loft_followup(r.id,'LOW_RATING',rev-'request_id');end if;
  end if;
  result:=result||public.plant_loft_tool_v10('get_request',jsonb_build_object('quote_code',coalesce(payload->>'quote_code',result->>'quote_code')));
  if result->>'confirmation_required'='true' then result:=result||jsonb_build_object('next_action','ACCEPT_LATEST_DELIVERY_VERSION_AND_TOTAL');end if;
  select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at),'[]') into f from public.plant_loft_followups c where c.request_id=r.id;
  result:=result||jsonb_build_object('followups',f,'owner_queue_recorded',jsonb_array_length(f)>0,'notification_status','QUEUED_IN_OWNER_SHEET_NOT_PUSHED',
   'return_reported',exists(select 1 from public.plant_loft_followups c where c.request_id=r.id and c.kind='RETURN_CLAIM'),
   'collection_confirmed',(select status='COMPLETED' and kind='RENTAL' from public.plant_loft_requests where id=r.id));
 end if;
 return result;
end $$;
create function public.plant_loft_owner(action text,payload jsonb)
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare result jsonb;
begin
 result:=public.plant_loft_owner_v10(action,payload);
 if action='returned' then update public.plant_loft_followups set status='RESOLVED',updated_at=now() where request_id=(payload->>'request_id')::uuid and kind='RETURN_CLAIM';end if;
 if action='snapshot' then result:=result||jsonb_build_object('followups',coalesce((select jsonb_agg(to_jsonb(c) order by c.created_at desc) from public.plant_loft_followups c),'[]'));end if;
 return result;
end $$;
revoke all on function public.plant_loft_followup(uuid,text,jsonb),public.plant_loft_check_demo_stock(text,jsonb),public.plant_loft_tool(text,jsonb),public.plant_loft_owner(text,jsonb) from public,anon,authenticated;
grant execute on function public.plant_loft_followup(uuid,text,jsonb),public.plant_loft_check_demo_stock(text,jsonb),public.plant_loft_tool(text,jsonb),public.plant_loft_owner(text,jsonb) to service_role;
commit;
