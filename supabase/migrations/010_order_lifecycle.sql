begin;
-- Preserve the proven quote/recovery implementation; add narrow lifecycle wrappers.
alter function public.plant_loft_tool(text,jsonb) rename to plant_loft_tool_v9;
alter function public.plant_loft_owner(text,jsonb) rename to plant_loft_owner_v9;
create table public.plant_loft_receipts (
 id uuid primary key default gen_random_uuid(), request_id uuid not null references public.plant_loft_requests(id),
 bank_reference text not null unique, amount_kobo bigint not null check(amount_kobo>0), pricing_version integer not null,
 confirmed_by text not null, created_at timestamptz not null default now()
);
create table public.plant_loft_reviews (
 request_id uuid primary key references public.plant_loft_requests(id), product_rating integer check(product_rating between 1 and 5),
 service_rating integer check(service_rating between 1 and 5), product_feedback text, service_feedback text, overall_feedback text,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.plant_loft_lifecycle_audit (
 id bigint generated always as identity primary key, request_id uuid not null references public.plant_loft_requests(id),
 action text not null, actor text not null, details jsonb not null default '{}', created_at timestamptz not null default now()
);
alter table public.plant_loft_receipts enable row level security;
alter table public.plant_loft_reviews enable row level security;
alter table public.plant_loft_lifecycle_audit enable row level security;
revoke all on public.plant_loft_receipts,public.plant_loft_reviews,public.plant_loft_lifecycle_audit from public,anon,authenticated;
grant all on public.plant_loft_receipts,public.plant_loft_reviews,public.plant_loft_lifecycle_audit to service_role;
grant usage,select on sequence public.plant_loft_lifecycle_audit_id_seq to service_role;

create function public.plant_loft_lifecycle(request_uuid uuid, operation text, payload jsonb, actor text)
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare r public.plant_loft_requests%rowtype; receipt public.plant_loft_receipts%rowtype; version integer; amount bigint;
 old_review public.plant_loft_reviews%rowtype; pr integer; sr integer; pf text; sf text; feedback text; next_state text;
begin
 select * into r from public.plant_loft_requests where id=request_uuid for update;
 if not found then raise exception 'Request not found'; end if;
 version:=coalesce((r.summary->>'transport_version')::integer,0);
 if operation='confirm_transfer' then
  if actor<>'OWNER' then raise exception 'Owner verification required'; end if;
  amount:=(payload->>'amount_kobo')::bigint;
  if payload->>'funds_received' is distinct from 'true' then raise exception 'Confirm bank funds received before saving'; end if;
  if length(trim(coalesce(payload->>'bank_reference',''))) not between 3 and 100 or length(trim(coalesce(payload->>'confirmed_by',''))) not between 2 and 80 then raise exception 'Bank reference and verifier required'; end if;
  if coalesce((payload->>'expected_version')::integer,-1)<>version then raise exception 'Pricing version changed; refresh'; end if;
  if amount is null or amount<=0 or amount is distinct from (r.summary->>'final_total_kobo')::bigint then raise exception 'Received amount must equal accepted total; partial/overpayment requires review'; end if;
  select * into receipt from public.plant_loft_receipts where bank_reference=trim(payload->>'bank_reference');
  if found then
   if receipt.request_id<>r.id or receipt.amount_kobo<>amount or receipt.pricing_version<>version then raise exception 'Bank reference already belongs to another receipt'; end if;
   return to_jsonb(r)-'session_id';
  end if;
  if r.status<>'AWAITING_PAYMENT' or r.summary->>'payment_status'<>'UNPAID' or r.summary->>'owner_approved' is distinct from 'true' or r.summary->>'transport_accepted' is distinct from 'true' then raise exception 'Request is not approved and awaiting payment; do not overwrite existing payment'; end if;
  insert into public.plant_loft_receipts(request_id,bank_reference,amount_kobo,pricing_version,confirmed_by)
   values(r.id,trim(payload->>'bank_reference'),amount,version,trim(payload->>'confirmed_by'));
  update public.plant_loft_requests set status='PAYMENT_RECEIVED_TEST',summary=summary||jsonb_build_object('payment_status','OWNER_CONFIRMED_TRANSFER_TEST','payment_verification','OWNER_BANK_CHECK','payment_confirmed_at',now()) where id=r.id;
 elsif operation='approve_stock' then
  if actor<>'OWNER' or payload->>'confirmed' is distinct from 'true' then raise exception 'Owner stock confirmation required'; end if;
  if r.summary->>'transport'<>'SELF_PICKUP' or r.summary->>'payment_status'<>'UNPAID' then raise exception 'Use delivery quote approval for delivery; do not change paid stock'; end if;
  if r.summary->>'owner_approved'='true' then return to_jsonb(r)-'session_id'; end if;
  update public.plant_loft_requests set status='AWAITING_PAYMENT',summary=summary||jsonb_build_object('owner_approved',true,'transport_accepted',true,'transport_version',coalesce((summary->>'transport_version')::integer,0),'owner_approved_at',now()) where id=r.id;
 elsif operation in ('received','delivered','returned') then
  if coalesce(r.summary->>'payment_status','') not in ('TEST_PAID','OWNER_CONFIRMED_TRANSFER_TEST') then raise exception 'Verify full payment before fulfilment'; end if;
  if operation in ('delivered','returned') and actor<>'OWNER' then raise exception 'Owner fulfilment action required'; end if;
  if payload->>'confirmed' is distinct from 'true' then raise exception 'Explicit fulfilment confirmation required'; end if;
  if operation='returned' and r.kind<>'RENTAL' then raise exception 'Return completion is for rentals only'; end if;
  if operation='returned' and coalesce(r.summary->>'fulfilment_status','')<>'RENTAL_IN_USE' and r.status<>'COMPLETED' then raise exception 'Record rental delivery before return'; end if;
  next_state:=case when r.kind='RENTAL' and operation<>'returned' then 'RENTAL_IN_USE' when operation='delivered' then 'DELIVERED' else 'COMPLETED' end;
  -- Duplicate/out-of-order confirmations never regress a completed order.
  if r.status='COMPLETED' or (r.summary->>'fulfilment_status'=next_state) then return to_jsonb(r)-'session_id'; end if;
  update public.plant_loft_requests set status=next_state,summary=summary||jsonb_build_object('fulfilment_status',next_state,
   'fulfilment_updated_at',now(),'fulfilment_confirmed_by',actor) where id=r.id;
 elsif operation='review' then
  if actor<>'CUSTOMER' then raise exception 'Customer review required'; end if;
  if (r.kind='SALE' and r.status not in ('DELIVERED','COMPLETED')) or (r.kind='RENTAL' and r.status<>'COMPLETED') then raise exception 'Review is available after fulfilment'; end if;
  pr:=(payload->>'product_rating')::integer; sr:=(payload->>'service_rating')::integer;
  pf:=nullif(trim(payload->>'product_feedback'),''); sf:=nullif(trim(payload->>'service_feedback'),''); feedback:=nullif(trim(payload->>'overall_feedback'),'');
  if pr is not null and pr not between 1 and 5 or sr is not null and sr not between 1 and 5 then raise exception 'Ratings must be 1 to 5'; end if;
  if coalesce(length(pf),0)>2000 or coalesce(length(sf),0)>2000 or coalesce(length(feedback),0)>2000 then raise exception 'Review text too long'; end if;
  if pr is null and sr is null and pf is null and sf is null and feedback is null then raise exception 'Review is empty'; end if;
  select * into old_review from public.plant_loft_reviews where request_id=r.id;
  if found then
   if old_review.product_rating is not distinct from pr and old_review.service_rating is not distinct from sr and old_review.product_feedback is not distinct from pf and old_review.service_feedback is not distinct from sf and old_review.overall_feedback is not distinct from feedback then return to_jsonb(r)-'session_id'; end if;
   if payload->>'replace_review' is distinct from 'true' then raise exception 'Review exists; explicit replacement confirmation required'; end if;
  end if;
  insert into public.plant_loft_reviews(request_id,product_rating,service_rating,product_feedback,service_feedback,overall_feedback)
  values(r.id,pr,sr,pf,sf,feedback) on conflict(request_id) do update set product_rating=excluded.product_rating,service_rating=excluded.service_rating,
   product_feedback=excluded.product_feedback,service_feedback=excluded.service_feedback,overall_feedback=excluded.overall_feedback,updated_at=now();
 else raise exception 'Unknown lifecycle operation'; end if;
 insert into public.plant_loft_lifecycle_audit(request_id,action,actor,details) values(r.id,operation,actor,jsonb_build_object('pricing_version',version));
 select * into r from public.plant_loft_requests where id=request_uuid;
 return to_jsonb(r)-'session_id';
end $$;

create function public.plant_loft_tool(action text,payload jsonb)
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare result jsonb; r public.plant_loft_requests%rowtype; review jsonb; op text:=payload->>'customer_action';
begin
 if op is not null and (action<>'get_request' or op not in ('received','review')) then raise exception 'Unsupported customer action'; end if;
 if action='prepare_quote' and payload->>'kind'='SALE' then
  if not (payload ? 'items') or exists(select 1 from jsonb_array_elements(payload->'items') x where not (x ? 'quantity') or jsonb_typeof(x->'quantity')<>'number' or (x->>'quantity')::numeric<>trunc((x->>'quantity')::numeric)) then raise exception 'Explicit whole-number quantity required for every plant'; end if;
 end if;
 result:=public.plant_loft_tool_v9(action,payload);
 if result->>'id' is not null and action in ('confirm_request','get_request') then
  if op is not null then
   -- Resolve ownership with the existing private-code lookup before mutation.
   if payload->>'quote_code' is null then raise exception 'Private recovery code required'; end if;
   perform public.plant_loft_lifecycle((result->>'id')::uuid,op,payload,'CUSTOMER');
   result:=public.plant_loft_tool_v9('get_request',jsonb_build_object('quote_code',payload->>'quote_code'));
  end if;
  select to_jsonb(v)-'request_id' into review from public.plant_loft_reviews v where v.request_id=(result->>'id')::uuid;
  result:=result||jsonb_build_object('review',review,'review_saved',review is not null,
   'review_eligible',result->>'status' in ('DELIVERED','COMPLETED'),
   'fulfilment_status',coalesce(result->'summary'->>'fulfilment_status','NOT_DELIVERED'));
 end if;
 return result;
end $$;

create function public.plant_loft_owner(action text,payload jsonb)
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare result jsonb;
begin
 if action in ('confirm_transfer','delivered','returned','approve_stock') then
  result:=public.plant_loft_lifecycle((payload->>'request_id')::uuid,action,payload,'OWNER');
 elsif action='snapshot' then
  result:=public.plant_loft_owner_v9(action,payload);
  result:=result||jsonb_build_object('reviews',coalesce((select jsonb_agg(to_jsonb(v) order by v.updated_at desc) from public.plant_loft_reviews v),'[]'),
   'receipts',coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc) from public.plant_loft_receipts p),'[]'));
 else result:=public.plant_loft_owner_v9(action,payload); end if;
 return result;
end $$;
revoke all on function public.plant_loft_lifecycle(uuid,text,jsonb,text),public.plant_loft_tool(text,jsonb),public.plant_loft_owner(text,jsonb) from public,anon,authenticated;
grant execute on function public.plant_loft_lifecycle(uuid,text,jsonb,text),public.plant_loft_tool(text,jsonb),public.plant_loft_owner(text,jsonb) to service_role;
commit;
