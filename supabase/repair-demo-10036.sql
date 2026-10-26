-- One-off correction to the synthetic rental from the customer's explicit transcript.
begin;
do $$
declare r public.plant_loft_requests%rowtype; patch jsonb;
begin
 select x.* into r from public.plant_loft_requests x join public.plant_loft_quotes q on q.id=x.quote_id
 where x.id='c2c7233e-548e-4954-a581-2201cce6cf3e' and q.customer_reference='10036' for update of x;
 if not found or r.kind<>'RENTAL' or (r.summary->>'final_total_kobo')::bigint<>7500000
 or r.summary->>'transport_accepted'<>'true' or r.summary->>'payment_status'<>'UNPAID'
 then raise exception 'Repair preconditions failed'; end if;
 patch:=jsonb_build_object('start_at','2026-11-01T15:00:00+01:00','end_at','2026-11-01T20:00:00+01:00',
 'rental_periods',1,'rental_hours_actual',5,'billing_period_hours',24,'owner_approved',true);
 update public.plant_loft_requests set summary=summary||patch,status='AWAITING_PAYMENT' where id=r.id;
 update public.plant_loft_quotes set summary=summary||patch where id=r.quote_id;
 insert into public.plant_loft_events(session_id,stage,kind,quote_id,request_id)
 values(r.session_id,'rental_timing_corrected',r.kind,r.quote_id,r.id);
end $$;
select q.customer_reference,r.status,r.summary->>'end_at' as actual_collection,
 r.summary->>'final_total_kobo' as accepted_total_kobo from public.plant_loft_requests r
 join public.plant_loft_quotes q on q.id=r.quote_id where q.customer_reference='10036';
commit;
