create table public.portal_section_validations(id uuid primary key default gen_random_uuid(),client_id uuid not null references public.portal_clients(id),month date not null check(extract(day from month)=1),section text not null check(section in ('shipments','inbounds','returns','carriers','storage')),payload jsonb not null,validated_at timestamptz not null default now(),validated_by uuid not null default auth.uid(),unique(client_id,month,section));
alter table public.portal_section_validations enable row level security;
revoke all on public.portal_section_validations from anon;
grant select,insert,update,delete on public.portal_section_validations to authenticated;
create policy section_validations_admin on public.portal_section_validations for all to authenticated using(exists(select 1 from public.portal_admins where user_id=(select auth.uid()))) with check(exists(select 1 from public.portal_admins where user_id=(select auth.uid())));
alter table public.portal_months add column workflow_managed boolean not null default false,add column validation_versions jsonb,add column carrier_total numeric(12,2) check(carrier_total>=0),add column storage_scope jsonb;
alter table public.portal_months drop constraint portal_months_storage_basis_check;
alter table public.portal_months add constraint portal_months_storage_basis_check check(storage_basis in ('manual','daily_average','validated_average'));
create function public.portal_section_snapshot(p_client uuid,p_month date,p_section text,p_start date default null,p_end date default null) returns jsonb language plpgsql security invoker set search_path='' as $$
declare first_day date:=date_trunc('month',p_month)::date; last_day date:=(date_trunc('month',p_month)+interval '1 month - 1 day')::date; data jsonb; payload jsonb; n integer; missing integer; zero_count integer; stock bigint; stock_date date; average numeric; from_day date:=coalesce(p_start,date_trunc('month',p_month)::date); to_day date:=coalesce(p_end,(date_trunc('month',p_month)+interval '1 month - 1 day')::date);
begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501';end if;
 if p_month<>first_day then raise exception 'Mese non valido';end if;
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
end $$;
revoke all on function public.portal_section_snapshot(uuid,date,text,date,date) from public,anon;
grant execute on function public.portal_section_snapshot(uuid,date,text,date,date) to authenticated;
create function public.portal_validate_section(p_client uuid,p_month date,p_section text,p_start date default null,p_end date default null,p_ack_partial boolean default false,p_ack_empty boolean default false,p_ack_issues boolean default false) returns jsonb language plpgsql security invoker set search_path='' as $$
declare snapshot jsonb; preinvoice_error text;
begin
 snapshot:=public.portal_section_snapshot(p_client,p_month,p_section,p_start,p_end);
 if (snapshot->>'rows')::integer=0 and not p_ack_empty then raise exception 'Conferma esplicitamente che non vi è attività per questa sezione';end if;
 if p_section='shipments' and ((snapshot->>'missing_pieces')::integer>0 or (snapshot->>'missing_labels')::integer>0) then raise exception 'Completa i pezzi spediti e le date etichetta importando i file ordini Deagor';end if;
 if p_section='carriers' and (snapshot->>'missing_charges')::integer>0 then raise exception 'Completa gli importi corriere al cliente prima di convalidare';end if;
 if p_section='carriers' and (snapshot->>'unmatched_shipments')::integer>0 and not p_ack_issues then raise exception 'Verifica le spedizioni prive di abbinamento a una fattura corriere';end if;
 if p_section='returns' and (snapshot->>'pending_returns')::integer>0 and not p_ack_issues then raise exception 'Conferma che i resi ancora aperti sono esclusi dal conteggio dei resi gestiti';end if;
 if p_section='storage' then
 if (snapshot->>'partial')::boolean and not p_ack_partial then raise exception 'Conferma la media sui soli giorni presenti e il periodo di attività';end if;
 if (snapshot->>'zero_volume_skus')::integer>0 and not p_ack_issues then raise exception 'Conferma gli articoli con volume zero';end if;
 if (snapshot->>'rows')::integer=0 then snapshot:=snapshot||jsonb_build_object('billable_m3',0,'stock_pieces',0);end if;
 end if;
 insert into public.portal_section_validations(client_id,month,section,payload) values(p_client,p_month,p_section,snapshot) on conflict(client_id,month,section) do update set payload=excluded.payload,validated_at=now(),validated_by=(select auth.uid());
 update public.portal_months set released=false where client_id=p_client and month=p_month;
 if (select count(*) from public.portal_section_validations where client_id=p_client and month=p_month)=5 then
 begin perform public.portal_build_preinvoice(p_client,p_month,false,false);exception when others then preinvoice_error:=SQLERRM;end;
 end if;
 return snapshot||jsonb_build_object('preinvoice_error',preinvoice_error);
end $$;
revoke all on function public.portal_validate_section(uuid,date,text,date,date,boolean,boolean,boolean) from public,anon;
grant execute on function public.portal_validate_section(uuid,date,text,date,date,boolean,boolean,boolean) to authenticated;
create function public.portal_build_preinvoice(p_client uuid,p_month date,p_confirm boolean default false,p_refresh_rates boolean default false,p_expected_versions jsonb default null,p_expected_lines jsonb default null) returns jsonb language plpgsql security invoker set search_path='' as $$
declare validation record; snapshot jsonb; quantities jsonb:='{}'; versions jsonb:='{}'; rates jsonb; lines jsonb:='[]'; r jsonb; q numeric; multiplier integer; price numeric; amount numeric; old_month public.portal_months%rowtype; c public.portal_clients%rowtype; missing integer:=0; space jsonb;
begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_client::text||p_month::text,0));
 if (select count(*) from public.portal_section_validations where client_id=p_client and month=p_month)<>5 then raise exception 'Convalida tutte le cinque sezioni prima di preparare la fatturazione';end if;
 for validation in select * from public.portal_section_validations where client_id=p_client and month=p_month order by section for update loop
 snapshot:=public.portal_section_snapshot(p_client,p_month,validation.section,(validation.payload->>'period_start')::date,(validation.payload->>'period_end')::date);
 if snapshot->>'signature'<>validation.payload->>'signature' then raise exception 'Dati modificati: riconvalida la sezione %',validation.section;end if;
 quantities:=quantities||validation.payload;versions:=versions||jsonb_build_object(validation.section,validation.id::text||'/'||validation.validated_at::text);
 if validation.section='storage' then space:=validation.payload;end if;
 end loop;
 select * into c from public.portal_clients where id=p_client;
 select * into old_month from public.portal_months where client_id=p_client and month=p_month for update;
 if old_month.workflow_managed and old_month.invoice_lines is not null and not p_refresh_rates then
 select coalesce(jsonb_agg(value order by ord),'[]') into rates from jsonb_array_elements(old_month.invoice_lines) with ordinality as entries(value,ord) where value->>'basis'<>'carrier_total';
 else rates:=coalesce(c.billing_rules,jsonb_build_array(jsonb_build_object('label','Logistica','basis','billable_shipments','mode','unit','rate',c.logistics_rate),jsonb_build_object('label','Spazio occupato','basis','billable_m3','mode','unit','rate',c.storage_rate),jsonb_build_object('label','Gestione resi','basis','billable_returns','mode','unit','rate',c.return_rate)));end if;
 for r in select value from jsonb_array_elements(rates) loop
 multiplier:=coalesce((r->>'multiple')::integer,1);if multiplier<1 then raise exception 'Multipli di deve essere almeno 1';end if;
 if r->>'mode'='fixed' then q:=1;
 elsif r->>'basis'='extra_pieces' then
 q:=(quantities->>'shipped_pieces')::numeric/multiplier-(quantities->>'billable_shipments')::numeric;
 if mod((quantities->>'shipped_pieces')::numeric,multiplier)<>0 then raise exception 'Pezzi spediti non divisibili per il kit da % pezzi',multiplier;end if;
 elsif r->>'basis' in ('shipped_pieces','received_pieces','stock_pieces') then
 q:=(quantities->>(r->>'basis'))::numeric/multiplier;
 if mod((quantities->>(r->>'basis'))::numeric,multiplier)<>0 then raise exception 'Quantità della voce % non divisibile per %',r->>'label',multiplier;end if;
 else q:=(quantities->>(r->>'basis'))::numeric;end if;
 if q is null or q<0 then raise exception 'Quantità non valida per la voce %',r->>'label';end if;
 price:=(r->>'rate')::numeric;if price<0 then raise exception 'Tariffa negativa';end if;
 amount:=case when r->>'mode'='included' then 0 else round(q*price,2) end;
 if amount is null then missing:=missing+1;end if;
 lines:=lines||jsonb_build_array(r||jsonb_build_object('multiple',multiplier,'quantity',q,'amount',amount));
 end loop;
 amount:=round((quantities->>'carrier_total')::numeric,2);
 lines:=lines||jsonb_build_array(jsonb_build_object('label','Trasporti corrieri','basis','carrier_total','mode','fixed','quantity',1,'rate',amount,'amount',amount));
 if p_confirm and (p_expected_versions is null or versions<>p_expected_versions or p_expected_lines is null or old_month.invoice_lines<>p_expected_lines) then raise exception 'Prefattura modificata: aggiorna e ricontrolla il dettaglio prima della conferma';end if;
 if p_confirm and missing>0 then raise exception 'Completa le tariffe applicate prima della conferma finale';end if;
 perform set_config('portal.workflow_confirmation','true',true);
 insert into public.portal_months(client_id,month,billable_shipments,shipped_pieces,received_pieces,stock_pieces,created_shipments,billable_returns,billable_m3,logistics_rate,storage_rate,return_rate,storage_basis,invoice_lines,carrier_total,storage_scope,validation_versions,workflow_managed,released)
 values(p_client,p_month,(quantities->>'billable_shipments')::integer,(quantities->>'shipped_pieces')::bigint,(quantities->>'received_pieces')::bigint,(quantities->>'stock_pieces')::bigint,(quantities->>'created_shipments')::bigint,(quantities->>'billable_returns')::integer,(quantities->>'billable_m3')::numeric,c.logistics_rate,c.storage_rate,c.return_rate,'validated_average',lines,amount,space,versions,true,p_confirm)
 on conflict(client_id,month) do update set billable_shipments=excluded.billable_shipments,shipped_pieces=excluded.shipped_pieces,received_pieces=excluded.received_pieces,stock_pieces=excluded.stock_pieces,created_shipments=excluded.created_shipments,billable_returns=excluded.billable_returns,billable_m3=excluded.billable_m3,storage_basis=excluded.storage_basis,invoice_lines=excluded.invoice_lines,carrier_total=excluded.carrier_total,storage_scope=excluded.storage_scope,validation_versions=excluded.validation_versions,workflow_managed=true,released=p_confirm;
 return jsonb_build_object('lines',lines,'missing_rates',missing,'confirmed',p_confirm);
end $$;
revoke all on function public.portal_build_preinvoice(uuid,date,boolean,boolean,jsonb,jsonb) from public,anon;
grant execute on function public.portal_build_preinvoice(uuid,date,boolean,boolean,jsonb,jsonb) to authenticated;
create function public.portal_workflow_invalidate() returns trigger language plpgsql security invoker set search_path='' as $$
declare rec jsonb; cid uuid; days date[]; sections text[]; affected date; linked public.portal_shipments%rowtype;
begin
 if TG_OP='UPDATE' and to_jsonb(OLD)=to_jsonb(NEW) then return null;end if;
 for rec in select v from (values(case when TG_OP<>'INSERT' then to_jsonb(OLD) end),(case when TG_OP<>'DELETE' then to_jsonb(NEW) end)) as records(v) where v is not null loop
 cid:=(rec->>'client_id')::uuid;
 if TG_TABLE_NAME='portal_shipments' then days:=array[(rec->>'shipped_on')::date,(rec->>'label_created_on')::date];sections:=array['shipments','carriers'];if TG_OP='UPDATE' and (to_jsonb(OLD)->'client_id',to_jsonb(OLD)->'shipped_on',to_jsonb(OLD)->'label_created_on',to_jsonb(OLD)->'order_number',to_jsonb(OLD)->'shipped_pieces') is not distinct from (to_jsonb(NEW)->'client_id',to_jsonb(NEW)->'shipped_on',to_jsonb(NEW)->'label_created_on',to_jsonb(NEW)->'order_number',to_jsonb(NEW)->'shipped_pieces') then sections:=array['carriers'];end if;
 elsif TG_TABLE_NAME='portal_inbounds' then days:=array[(rec->>'received_on')::date];sections:=array['inbounds'];
 elsif TG_TABLE_NAME='portal_returns' then days:=array[(rec->>'received_on')::date];sections:=array['returns'];
 elsif TG_TABLE_NAME='portal_storage_days' then days:=array[(rec->>'observed_on')::date];sections:=array['storage'];
 else select * into linked from public.portal_shipments where id=(rec->>'shipment_id')::uuid;cid:=linked.client_id;days:=array[(rec->>'month')::date,linked.shipped_on];sections:=array['carriers'];end if;
 for affected in select distinct date_trunc('month',d)::date from unnest(days) d where d is not null loop
 delete from public.portal_section_validations where client_id=cid and month=affected and section=any(sections);
 update public.portal_months set released=false where client_id=cid and month=affected and workflow_managed;
 end loop;
 end loop;
 return null;
end $$;
revoke all on function public.portal_workflow_invalidate() from public,anon,authenticated;
create trigger workflow_shipments after insert or update or delete on public.portal_shipments for each row execute function public.portal_workflow_invalidate();
create trigger workflow_inbounds after insert or update or delete on public.portal_inbounds for each row execute function public.portal_workflow_invalidate();
create trigger workflow_returns after insert or update or delete on public.portal_returns for each row execute function public.portal_workflow_invalidate();
create trigger workflow_storage after insert or update or delete on public.portal_storage_days for each row execute function public.portal_workflow_invalidate();
create trigger workflow_carriers after insert or update or delete on public.portal_carrier_charges for each row execute function public.portal_workflow_invalidate();
create function public.portal_guard_workflow_confirmation() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if NEW.workflow_managed and NEW.released and current_setting('portal.workflow_confirmation',true) is distinct from 'true' then raise exception 'Usa la conferma finale della sezione Fatturazione';end if;
 return NEW;
end $$;
revoke all on function public.portal_guard_workflow_confirmation() from public,anon,authenticated;
create trigger guard_workflow_confirmation before insert or update on public.portal_months for each row execute function public.portal_guard_workflow_confirmation();
create function public.portal_apply_brt_costs(p_client uuid,p_month date,p_quotes jsonb) returns integer language plpgsql security invoker set search_path='' as $$
declare r record; shipment public.portal_shipments%rowtype; total numeric; changed integer:=0;
begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501';end if;
 if jsonb_typeof(p_quotes)<>'array' or jsonb_array_length(p_quotes)>5000 then raise exception 'Proposta non valida';end if;
 for r in select * from jsonb_to_recordset(p_quotes) as x(shipment_id uuid,cost numeric) loop
 select * into shipment from public.portal_shipments where id=r.shipment_id and client_id=p_client and date_trunc('month',shipped_on)::date=p_month for update;
 if shipment.id is null or shipment.customer_charge is not null then raise exception 'Spedizione o importo modificato: aggiorna la proposta';end if;
 select round(sum(transport+fuel+extras),2) into total from public.portal_carrier_charges where shipment_id=shipment.id;
 if total is null or total is distinct from r.cost then raise exception 'Costo BRT modificato: aggiorna la proposta';end if;
 update public.portal_shipments set customer_charge=total where id=shipment.id;
 changed:=changed+1;
 end loop;
 return changed;
end $$;
revoke all on function public.portal_apply_brt_costs(uuid,date,jsonb) from public,anon;
grant execute on function public.portal_apply_brt_costs(uuid,date,jsonb) to authenticated;
