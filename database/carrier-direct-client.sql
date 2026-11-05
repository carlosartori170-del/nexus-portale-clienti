-- Destinazione diretta al cliente, senza spedizione Deagor. Applicare dopo approvazione.
alter table public.portal_carrier_charges add column direct_client_id uuid references public.portal_clients(id);
create index portal_carrier_charges_direct_client_month on public.portal_carrier_charges(direct_client_id,month) where direct_client_id is not null;
alter table public.portal_carrier_charges add constraint portal_carrier_one_destination check ((case when nexus_owned then 1 else 0 end)+(case when shipment_id is not null then 1 else 0 end)+(case when direct_client_id is not null then 1 else 0 end)<=1);
comment on column public.portal_carrier_charges.direct_client_id is 'Costo riaddebitato direttamente al cliente sul nostro contratto, senza ordine Deagor.';
CREATE OR REPLACE FUNCTION public.portal_assign_carrier_destination(p_charge uuid, p_nexus_owned boolean, p_shipment uuid, p_expected jsonb, p_clear_customer_charge boolean DEFAULT false, p_expected_customer_charge numeric DEFAULT NULL::numeric, p_direct_client uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare c public.portal_carrier_charges%rowtype; old_shipment public.portal_shipments%rowtype; target public.portal_shipments%rowtype;
begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501';end if;
 if p_nexus_owned is null then raise exception 'Destinazione del costo mancante';end if;
 select * into c from public.portal_carrier_charges where id=p_charge for update;
 if not found then raise exception 'Addebito non trovato';end if;
 if p_expected is null or to_jsonb(c)<>p_expected then raise exception 'Addebito modificato: riapri l’anteprima';end if;
 if (p_nexus_owned and (p_shipment is not null or p_direct_client is not null)) or (p_shipment is not null and p_direct_client is not null) then raise exception 'Scegli una sola destinazione: spedizione, cliente diretto o Nexus';end if;
 perform 1 from public.portal_shipments where id=c.shipment_id or id=p_shipment order by id for update;
 if c.shipment_id is not null then select * into old_shipment from public.portal_shipments where id=c.shipment_id;end if;
 if (p_nexus_owned or p_direct_client is not null) and c.shipment_id is not null then
  if old_shipment.customer_charge is distinct from p_expected_customer_charge then raise exception 'Importo al cliente modificato: riapri l’anteprima';end if;
  if old_shipment.customer_charge is not null then
   if not coalesce(p_clear_customer_charge,false) then raise exception 'Conferma la rimozione del precedente importo cliente prima di cambiare destinazione';end if;
   if exists(select 1 from public.portal_carrier_charges where shipment_id=c.shipment_id and id<>c.id) then raise exception 'La spedizione ha altri costi collegati: verifica prima l’importo al cliente e gli abbinamenti';end if;
   update public.portal_shipments set customer_charge=null where id=c.shipment_id;
  end if;
 end if;
 if p_direct_client is not null then
  perform 1 from public.portal_clients where id=p_direct_client for key share;
  if not found then raise exception 'Cliente diretto non trovato';end if;
 end if;
 if p_shipment is not null then
  select * into target from public.portal_shipments where id=p_shipment;
  if not found then raise exception 'Spedizione non trovata';end if;
  if exists(select 1 from public.portal_clients where id=target.client_id and (billing_quantity_source='manual' or billing_daily_shipments)) then raise exception 'Cliente con gestione manuale / contratto proprio: verifica la destinazione del costo';end if;
  if c.invoice_number='CSV SPEDIAMO PRO' and exists(select 1 from public.portal_carrier_charges where shipment_id=p_shipment and id<>p_charge) then raise exception 'Su questa spedizione è già presente un costo: verifica per evitare duplicati';end if;
 end if;
 update public.portal_carrier_charges
 set direct_client_id=p_direct_client,nexus_owned=p_nexus_owned,shipment_id=case when p_nexus_owned then null else p_shipment end,
 shipped_on=case when not p_nexus_owned and p_shipment is not null and (invoice_number='CSV SPEDIAMO PRO' or invoice_number like 'INPOST %') then target.shipped_on else shipped_on end,
 month=case when not p_nexus_owned and p_shipment is not null and invoice_number='CSV SPEDIAMO PRO' then date_trunc('month',target.shipped_on)::date else month end
 where id=p_charge returning * into c;
 return to_jsonb(c);
end $function$
;
revoke all on function public.portal_assign_carrier_destination(uuid,boolean,uuid,jsonb,boolean,numeric,uuid) from public,anon;
grant execute on function public.portal_assign_carrier_destination(uuid,boolean,uuid,jsonb,boolean,numeric,uuid) to authenticated;
CREATE OR REPLACE FUNCTION public.portal_billing_requirements(p_client uuid, p_month date, p_refresh_rates boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare c public.portal_clients%rowtype; m public.portal_months%rowtype; rates jsonb; r jsonb; fields jsonb:='[]'; sections jsonb:='[]'; f text; s text;
begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501';end if;
 select * into c from public.portal_clients where id=p_client;
 if not found then raise exception 'Cliente non trovato';end if;
 select * into m from public.portal_months where client_id=p_client and month=p_month;
 if m.workflow_managed and m.invoice_lines is not null and not p_refresh_rates then
 select coalesce(jsonb_agg(value order by ord),'[]') into rates from jsonb_array_elements(m.invoice_lines) with ordinality e(value,ord) where value->>'basis' not in ('carrier_total','logistics_minimum','transport_charge');
 else rates:=coalesce(c.billing_rules,jsonb_build_array(jsonb_build_object('basis','billable_shipments','mode','unit'),jsonb_build_object('basis','billable_m3','mode','unit'),jsonb_build_object('basis','billable_returns','mode','unit')));end if;
 for r in select value from jsonb_array_elements(rates) loop
 if r->>'mode' in ('fixed','included') then continue;end if;
 for f in select jsonb_array_elements_text(case when r->>'basis'='extra_pieces' or coalesce((r->>'per_order_pieces')::numeric,0)>0 then '["billable_shipments","shipped_pieces"]'::jsonb else jsonb_build_array(r->>'basis') end) loop
 if f not in ('billable_shipments','shipped_pieces','created_shipments','received_pieces','billable_returns','billable_m3','stock_pieces') then raise exception 'Quantità tariffaria non valida: %',f;end if;
 if not fields ? f then fields:=fields||jsonb_build_array(f);end if;
 end loop;end loop;
 -- Existing, separately billed courier costs remain in the invoice.
 if c.billing_quantity_source='deagor' and (exists(select 1 from public.portal_shipments s where s.client_id=p_client and s.shipped_on>=p_month and s.shipped_on<p_month+interval '1 month' and (s.customer_charge is not null or exists(select 1 from public.portal_carrier_charges ch where ch.shipment_id=s.id))) or exists(select 1 from jsonb_array_elements(coalesce(m.invoice_lines,'[]')) x where x->>'basis'='carrier_total' and coalesce((x->>'amount')::numeric,0)>0)) then fields:=fields||'["carrier_total"]'::jsonb;end if;
 if exists(select 1 from public.portal_carrier_charges where direct_client_id=p_client and month=p_month and not nexus_owned) and not fields ? 'carrier_total' then fields:=fields||'["carrier_total"]'::jsonb;end if;
 foreach s in array array['shipments','inbounds','returns','carriers','storage'] loop
 if (s='shipments' and fields ?| array['billable_shipments','shipped_pieces','created_shipments']) or (s='inbounds' and fields ? 'received_pieces') or (s='returns' and fields ? 'billable_returns') or (s='carriers' and fields ? 'carrier_total') or (s='storage' and fields ?| array['billable_m3','stock_pieces']) then sections:=sections||jsonb_build_array(s);end if;
 end loop;
 return jsonb_build_object('source',c.billing_quantity_source,'fields',fields,'sections',sections);
end $function$
;
CREATE OR REPLACE FUNCTION public.portal_section_snapshot(p_client uuid, p_month date, p_section text, p_start date DEFAULT NULL::date, p_end date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare direct_data jsonb; direct_total numeric; direct_count integer; first_day date:=date_trunc('month',p_month)::date; last_day date:=(date_trunc('month',p_month)+interval '1 month - 1 day')::date; data jsonb; payload jsonb; n integer; missing integer; zero_count integer; stock bigint; stock_date date; average numeric; from_day date:=coalesce(p_start,date_trunc('month',p_month)::date); to_day date:=coalesce(p_end,(date_trunc('month',p_month)+interval '1 month - 1 day')::date);
begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501';end if;
 if p_month is null or p_month<>first_day then raise exception 'Mese non valido';end if;
 if p_section='shipments' and exists(select 1 from public.portal_clients where id=p_client and billing_daily_shipments and billing_quantity_source='manual') then
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'date',shipped_on,'received',received_on,'supplier',supplier,'pieces',piece_count,'shipments',shipment_count,'notes',notes) order by id),'[]'),count(*),jsonb_build_object('billable_shipments',coalesce(sum(shipment_count),0),'daily_piece_count',coalesce(sum(piece_count),0)) into data,n,payload from public.portal_daily_dispatches where client_id=p_client and shipped_on between first_day and last_day;
 return payload||jsonb_build_object('source','daily','rows',n,'signature',md5(data::text));
 end if;
 if (select billing_quantity_source from public.portal_clients where id=p_client)='manual' and p_section<>'carriers' then
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
 if p_section='carriers' then
 select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'client',c.direct_client_id,'month',c.month,'invoice',c.invoice_number,'code',c.carrier_code,'transport',c.transport,'fuel',c.fuel,'extras',c.extras) order by c.id),'[]'),coalesce(sum(c.transport+c.fuel+c.extras),0),count(*)
 into direct_data,direct_total,direct_count from public.portal_carrier_charges c where c.direct_client_id=p_client and c.month=p_month and not c.nexus_owned;
 payload:=payload||jsonb_build_object('carrier_total',coalesce((payload->>'carrier_total')::numeric,0)+direct_total,'direct_carrier_total',direct_total,'direct_carrier_count',direct_count);
 if direct_count>0 then data:=data||direct_data;n:=n+direct_count;end if;
 if (select billing_quantity_source from public.portal_clients where id=p_client)='manual' then payload:=payload||jsonb_build_object('source','direct');end if;
 end if;
 return payload||jsonb_build_object('rows',n,'signature',md5(data::text));
end $function$
;
CREATE OR REPLACE FUNCTION public.portal_workflow_invalidate()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare rec jsonb; cid uuid; days date[]; sections text[]; affected date; linked public.portal_shipments%rowtype;
begin
 if TG_OP='UPDATE' and to_jsonb(OLD)=to_jsonb(NEW) then return null;end if;
 for rec in select v from (values(case when TG_OP<>'INSERT' then to_jsonb(OLD) end),(case when TG_OP<>'DELETE' then to_jsonb(NEW) end)) as records(v) where v is not null loop
 cid:=(rec->>'client_id')::uuid;
 if TG_TABLE_NAME='portal_shipments' then days:=array[(rec->>'shipped_on')::date,(rec->>'label_created_on')::date];sections:=array['shipments','carriers'];if TG_OP='UPDATE' and (to_jsonb(OLD)->'client_id',to_jsonb(OLD)->'shipped_on',to_jsonb(OLD)->'label_created_on',to_jsonb(OLD)->'order_number',to_jsonb(OLD)->'shipped_pieces') is not distinct from (to_jsonb(NEW)->'client_id',to_jsonb(NEW)->'shipped_on',to_jsonb(NEW)->'label_created_on',to_jsonb(NEW)->'order_number',to_jsonb(NEW)->'shipped_pieces') then sections:=array['carriers'];end if;
 elsif TG_TABLE_NAME='portal_inbounds' then days:=array[(rec->>'received_on')::date];sections:=array['inbounds'];
 elsif TG_TABLE_NAME='portal_returns' then days:=array[(rec->>'received_on')::date];sections:=array['returns'];
 elsif TG_TABLE_NAME='portal_storage_days' then days:=array[(rec->>'observed_on')::date];sections:=array['storage'];
 else select * into linked from public.portal_shipments where id=(rec->>'shipment_id')::uuid;cid:=coalesce((rec->>'direct_client_id')::uuid,linked.client_id);days:=array[(rec->>'month')::date,linked.shipped_on];sections:=array['carriers'];end if;
 for affected in select distinct date_trunc('month',d)::date from unnest(days) d where d is not null loop
 delete from public.portal_section_validations where client_id=cid and month=affected and section=any(sections);
 update public.portal_months set released=false where client_id=cid and month=affected and workflow_managed;
 end loop;
 end loop;
 return null;
end $function$
;
