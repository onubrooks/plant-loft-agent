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
