begin;
create table public.plant_loft_payment_attempts (
 id uuid primary key default gen_random_uuid(), request_id uuid not null references public.plant_loft_requests(id),
 transport_version integer not null, method text not null check(method in ('CHECKOUT','BANK_TRANSFER')),
 reference text not null unique, amount_kobo bigint not null check(amount_kobo>0),
 status text not null default 'NEW', provider_data jsonb not null default '{}', created_at timestamptz not null default now(),
 unique(request_id,transport_version,method)
);
alter table public.plant_loft_payment_attempts enable row level security;
revoke all on public.plant_loft_payment_attempts from public,anon,authenticated;
grant all on public.plant_loft_payment_attempts to service_role;
create function public.plant_loft_prepare_payments(request_uuid uuid)
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare r public.plant_loft_requests%rowtype; v integer; a bigint; methods text;
begin
 select * into r from public.plant_loft_requests where id=request_uuid for update;
 if not found then raise exception 'Request not found'; end if;
 if r.status<>'AWAITING_PAYMENT' or r.summary->>'owner_approved' is distinct from 'true'
  or r.summary->>'transport_accepted' is distinct from 'true' or r.summary->>'payment_status'<>'UNPAID' then raise exception 'Payment not ready'; end if;
 v:=(r.summary->>'transport_version')::integer; a:=(r.summary->>'final_total_kobo')::bigint;
 if v is null or a is null or a<=0 then raise exception 'Invalid approved payment total'; end if;
 foreach methods in array array['CHECKOUT','BANK_TRANSFER'] loop
  insert into public.plant_loft_payment_attempts(request_id,transport_version,method,reference,amount_kobo)
   values(r.id,v,methods,'PL-'||r.id::text||'-v'||v::text||'-'||replace(methods,'_','-'),a)
   on conflict(request_id,transport_version,method) do nothing;
 end loop;
 return (select jsonb_agg(to_jsonb(p)) from public.plant_loft_payment_attempts p where request_id=r.id and transport_version=v);
end $$;
create function public.plant_loft_apply_test_payment(payment_reference text)
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare p public.plant_loft_payment_attempts%rowtype; r public.plant_loft_requests%rowtype;
begin
 select * into p from public.plant_loft_payment_attempts where reference=payment_reference for update;
 if not found then raise exception 'Unknown payment reference'; end if;
 select * into r from public.plant_loft_requests where id=p.request_id for update;
 if p.amount_kobo<>(r.summary->>'final_total_kobo')::bigint or p.transport_version<>(r.summary->>'transport_version')::integer then raise exception 'Stale payment needs reconciliation'; end if;
 if r.summary->>'payment_status'='TEST_PAID' then return jsonb_build_object('already_paid',true,'request_id',r.id); end if;
 if r.status<>'AWAITING_PAYMENT' then raise exception 'Request not awaiting payment'; end if;
 update public.plant_loft_payment_attempts set status='VERIFIED_TEST_PAID' where id=p.id;
 update public.plant_loft_requests set status='PAYMENT_RECEIVED_TEST',summary=summary||jsonb_build_object('payment_status','TEST_PAID','payment_reference',payment_reference)
  where id=r.id;
 return jsonb_build_object('request_id',r.id,'payment_status','TEST_PAID');
end $$;
revoke all on function public.plant_loft_prepare_payments(uuid), public.plant_loft_apply_test_payment(text) from public,anon,authenticated;
grant execute on function public.plant_loft_prepare_payments(uuid), public.plant_loft_apply_test_payment(text) to service_role;
commit;
