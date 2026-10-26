begin;
create or replace function public.plant_loft_tool(action text,payload jsonb)
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
commit;
