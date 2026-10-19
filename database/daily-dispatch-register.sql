begin;
alter table public.portal_clients add column billing_daily_shipments boolean not null default false;
create table public.portal_daily_dispatches (
 id uuid primary key default gen_random_uuid(), client_id uuid not null references public.portal_clients(id),
 shipped_on date not null, received_on date not null, supplier text not null check(length(trim(supplier)) between 1 and 200),
 piece_count bigint not null check(piece_count between 0 and 9007199254740991), shipment_count integer not null check(shipment_count>=0),
 notes text not null default '' check(length(notes)<=2000),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(), updated_by uuid default auth.uid()
);
create index portal_daily_dispatches_client_date on public.portal_daily_dispatches(client_id,shipped_on);
alter table public.portal_daily_dispatches enable row level security;
revoke all on public.portal_daily_dispatches from anon;
grant select,insert,update,delete on public.portal_daily_dispatches to authenticated;
create policy daily_dispatch_admin on public.portal_daily_dispatches to authenticated
 using(exists(select 1 from public.portal_admins where user_id=(select auth.uid())))
 with check(exists(select 1 from public.portal_admins where user_id=(select auth.uid())));
create policy daily_dispatch_customer_read on public.portal_daily_dispatches for select to authenticated
 using(client_id in (select client_id from public.portal_members where user_id=(select auth.uid())));
create or replace function public.portal_daily_dispatch_guard() returns trigger language plpgsql security invoker set search_path='' as $$
declare old_client uuid; old_month date; new_client uuid; new_month date; target record;
begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501';end if;
 if TG_OP in ('UPDATE','DELETE') then old_client:=old.client_id;old_month:=date_trunc('month',old.shipped_on)::date;end if;
 if TG_OP in ('UPDATE','INSERT') then new_client:=new.client_id;new_month:=date_trunc('month',new.shipped_on)::date;end if;
 for target in select distinct v.client_id,v.month from (values(old_client,old_month),(new_client,new_month)) v(client_id,month) where v.client_id is not null order by v.client_id,v.month loop
 perform pg_advisory_xact_lock(hashtextextended(target.client_id::text||target.month::text,0));
 end loop;
 if TG_OP='DELETE' then return old;end if;
 if not exists(select 1 from public.portal_clients where id=new.client_id and billing_daily_shipments and billing_quantity_source='manual') then raise exception 'Registro giornaliero non attivo per questo cliente';end if;
 new.supplier:=trim(new.supplier);new.updated_at:=clock_timestamp();new.updated_by:=(select auth.uid());
 return new;
end $$;
create trigger daily_dispatch_guard before insert or update or delete on public.portal_daily_dispatches for each row execute function public.portal_daily_dispatch_guard();
create or replace function public.portal_daily_dispatch_invalidate() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if TG_OP in ('UPDATE','DELETE') then
 delete from public.portal_section_validations where client_id=old.client_id and month=date_trunc('month',old.shipped_on)::date and section='shipments';
 update public.portal_months set released=false where client_id=old.client_id and month=date_trunc('month',old.shipped_on)::date;
 end if;
 if TG_OP in ('INSERT','UPDATE') then
 delete from public.portal_section_validations where client_id=new.client_id and month=date_trunc('month',new.shipped_on)::date and section='shipments';
 update public.portal_months set released=false where client_id=new.client_id and month=date_trunc('month',new.shipped_on)::date;
 end if;
 return null;
end $$;
create trigger daily_dispatch_invalidate after insert or update or delete on public.portal_daily_dispatches for each row execute function public.portal_daily_dispatch_invalidate();
revoke all on function public.portal_daily_dispatch_guard() from public,anon;
revoke all on function public.portal_daily_dispatch_invalidate() from public,anon;
CREATE OR REPLACE FUNCTION public.portal_section_snapshot(p_client uuid, p_month date, p_section text, p_start date DEFAULT NULL::date, p_end date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare first_day date:=date_trunc('month',p_month)::date; last_day date:=(date_trunc('month',p_month)+interval '1 month - 1 day')::date; data jsonb; payload jsonb; n integer; missing integer; zero_count integer; stock bigint; stock_date date; average numeric; from_day date:=coalesce(p_start,date_trunc('month',p_month)::date); to_day date:=coalesce(p_end,(date_trunc('month',p_month)+interval '1 month - 1 day')::date);
begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501';end if;
 if p_month is null or p_month<>first_day then raise exception 'Mese non valido';end if;
 if p_section='shipments' and exists(select 1 from public.portal_clients where id=p_client and billing_daily_shipments and billing_quantity_source='manual') then
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'date',shipped_on,'received',received_on,'supplier',supplier,'pieces',piece_count,'shipments',shipment_count,'notes',notes) order by id),'[]'),count(*),jsonb_build_object('billable_shipments',coalesce(sum(shipment_count),0),'daily_piece_count',coalesce(sum(piece_count),0)) into data,n,payload from public.portal_daily_dispatches where client_id=p_client and shipped_on between first_day and last_day;
 return payload||jsonb_build_object('source','daily','rows',n,'signature',md5(data::text));
 end if;
 if (select billing_quantity_source from public.portal_clients where id=p_client)='manual' then
 select quantities into payload from public.portal_manual_billing_quantities where client_id=p_client and month=p_month and section=p_section;
 if payload is null then raise exception 'Inserisci e convalida le quantità mensili di questa sezione';end if;
 return payload||jsonb_build_object('source','manual','rows',1,'signature',md5(payload::text));
 end if;
 if p_section='shipments' then
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'code',code,'order',order_number,'date',shipped_on,'pieces',shipped_pieces,'label',label_created_on) order by id),'[]') into data from public.portal_shipments where client_id=p_client and (shipped_on between first_day and last_day or label_created_on between first_day and last_day);
 select count(*),count(*) filter(where shipped_pieces is null),jsonb_build_object('billable_shipments',count(distinct coalesce(nullif(trim(order_number),''),code)),'shipped_pieces',coalesce(sum(shipped_pieces),0)) into n,missing,payload from public.portal_shipments where client_id=p_client and shipped_on between first_day and last_day;
 payload:=payload||jsonb_build_object('created_shipments',(select count(*) from public.portal_shipments where client_id=p_client and label_created_on between first_day and last_day),'missing_pieces',missing,'missing_labels',(select count(*) from public.portal_shipments where client_id=p_client and shipped_on between first_day and last_day and label_created_on is null));
 elsif p_section='inbounds' then
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'date',received_on,'pieces',total_pieces,'code',code) order by id),'[]'),count(*),jsonb_build_object('received_pieces',coalesce(sum(total_pieces),0)) into data,n,payload from public.portal_inbounds where client_id=p_client and received_on between first_day and last_day;
 elsif p_section='returns' then
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'date',received_on,'status',status,'shipment',shipment_code) order by id),'[]'),count(*),jsonb_build_object('billable_returns',count(*) filter(where status='Chiuso'),'pending_returns',count(*) filter(where status<>'Chiuso')) into data,n,payload from public.portal_returns where client_id=p_client and received_on between first_day and last_day;
 elsif p_section='carriers' then
 select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'date',s.shipped_on,'charge',s.customer_charge,'supplier',(select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'invoice',c.invoice_number,'transport',c.transport,'fuel',c.fuel,'extras',c.extras) order by c.id),'[]') from public.portal_carrier_charges c where c.shipment_id=s.id)) order by s.id),'[]'),count(*),jsonb_build_object('carrier_total',coalesce(sum(s.customer_charge),0),'missing_charges',count(*) filter(where s.customer_charge is null),'unmatched_shipments',count(*) filter(where not exists(select 1 from public.portal_carrier_charges c where c.shipment_id=s.id))) into data,n,payload from public.portal_shipments s where s.client_id=p_client and s.shipped_on between first_day and last_day;
 elsif p_section='storage' then
 if from_day<first_day or to_day>last_day or from_day>to_day then raise exception 'Periodo spazio non valido';end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'date',observed_on,'volume',volume_m3,'units',total_units,'zero',zero_volume_skus) order by id),'[]'),count(*),round(avg(volume_m3),8),coalesce(sum(zero_volume_skus),0) into data,n,average,zero_count from public.portal_storage_days where client_id=p_client and observed_on between from_day and to_day;
 select total_units,observed_on into stock,stock_date from public.portal_storage_days where client_id=p_client and observed_on between from_day and to_day order by observed_on desc limit 1;
 payload:=jsonb_build_object('billable_m3',average,'stock_pieces',stock,'stock_date',stock_date,'period_start',from_day,'period_end',to_day,'days',n,'expected_days',to_day-from_day+1,'month_days',last_day-first_day+1,'partial',n<>last_day-first_day+1 or from_day<>first_day or to_day<>last_day,'zero_volume_skus',zero_count);
 else raise exception 'Sezione non valida';end if;
 return payload||jsonb_build_object('rows',n,'signature',md5(data::text));
end $function$

;
CREATE OR REPLACE FUNCTION public.portal_validate_manual_section(p_client uuid, p_month date, p_section text, p_quantities jsonb, p_ack_empty boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare req jsonb; allowed_fields text[]; f text; value numeric; clean jsonb:='{}'; needed integer:=0;
begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_client::text||p_month::text,0));
 if p_month is null or p_month<>date_trunc('month',p_month)::date then raise exception 'Mese non valido';end if;
 if p_section='shipments' and exists(select 1 from public.portal_clients where id=p_client and billing_daily_shipments) then raise exception 'Le spedizioni del mese sono calcolate dal registro giornaliero: modifica e convalida il registro';end if;
 req:=public.portal_billing_requirements(p_client,p_month);
 if req->>'source'<>'manual' or not (req->'sections') ? p_section then raise exception 'Sezione non prevista per questo cliente';end if;
 if jsonb_typeof(p_quantities) is distinct from 'object' then raise exception 'Quantità non valide';end if;
 allowed_fields:=case p_section when 'shipments' then array['billable_shipments','shipped_pieces','created_shipments'] when 'inbounds' then array['received_pieces'] when 'returns' then array['billable_returns'] when 'storage' then array['billable_m3','stock_pieces'] else array[]::text[] end;
 for f in select jsonb_array_elements_text(req->'fields') loop
 if not f=any(allowed_fields) then continue;end if;
 needed:=needed+1;
 if jsonb_typeof(p_quantities->f) is distinct from 'number' then raise exception 'Inserisci la quantità %',f;end if;
 value:=(p_quantities->>f)::numeric;
 if value<0 or value>9007199254740991 or (f<>'billable_m3' and value<>trunc(value)) or (f in ('billable_shipments','billable_returns') and value>2147483647) then raise exception 'Quantità non valida: %',f;end if;
 clean:=clean||jsonb_build_object(f,value);
 end loop;
 if needed=0 or (select count(*) from jsonb_object_keys(p_quantities))<>needed then raise exception 'Sono consentite soltanto le quantità previste dalle tariffe';end if;
 if not p_ack_empty and not exists(select 1 from jsonb_each_text(clean) e where e.value::numeric>0) then raise exception 'Conferma esplicitamente il conteggio zero';end if;
 insert into public.portal_manual_billing_quantities(client_id,month,section,quantities) values(p_client,p_month,p_section,clean)
 on conflict(client_id,month,section) do update set quantities=excluded.quantities,updated_at=now(),updated_by=(select auth.uid());
 return public.portal_validate_section(p_client,p_month,p_section,null,null,true,true,true);
end $function$

;
update public.portal_clients set billing_daily_shipments=true where id='84e2e54b-935d-476d-98a8-c7f5bae716d5' and billing_quantity_source='manual';
commit;
