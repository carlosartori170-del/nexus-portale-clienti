-- Configure billed quantities per customer; preserve existing invoice snapshots.
begin;
alter table public.portal_clients add column if not exists billing_quantity_source text not null default 'deagor' check (billing_quantity_source in ('deagor','manual'));
create table public.portal_manual_billing_quantities (
 client_id uuid not null references public.portal_clients(id), month date not null check(extract(day from month)=1),
 section text not null check(section in ('shipments','inbounds','returns','carriers','storage')),
 quantities jsonb not null check(jsonb_typeof(quantities)='object'),
 updated_at timestamptz not null default now(), updated_by uuid not null default auth.uid(), primary key(client_id,month,section)
);
alter table public.portal_manual_billing_quantities enable row level security;
revoke all on public.portal_manual_billing_quantities from anon;
grant select,insert,update,delete on public.portal_manual_billing_quantities to authenticated;
create policy manual_billing_admin on public.portal_manual_billing_quantities to authenticated
 using (exists(select 1 from public.portal_admins where user_id=(select auth.uid())))
 with check (exists(select 1 from public.portal_admins where user_id=(select auth.uid())));
create or replace function public.portal_billing_requirements(p_client uuid,p_month date,p_refresh_rates boolean default false)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
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
 for f in select jsonb_array_elements_text(case when r->>'basis'='extra_pieces' then '["billable_shipments","shipped_pieces"]'::jsonb else jsonb_build_array(r->>'basis') end) loop
 if f not in ('billable_shipments','shipped_pieces','created_shipments','received_pieces','billable_returns','billable_m3','stock_pieces') then raise exception 'Quantità tariffaria non valida: %',f;end if;
 if not fields ? f then fields:=fields||jsonb_build_array(f);end if;
 end loop;end loop;
 -- Existing, separately billed courier costs remain in the invoice.
 if c.billing_quantity_source='deagor' and (exists(select 1 from public.portal_shipments s where s.client_id=p_client and s.shipped_on>=p_month and s.shipped_on<p_month+interval '1 month' and (s.customer_charge is not null or exists(select 1 from public.portal_carrier_charges ch where ch.shipment_id=s.id))) or exists(select 1 from jsonb_array_elements(coalesce(m.invoice_lines,'[]')) x where x->>'basis'='carrier_total' and coalesce((x->>'amount')::numeric,0)>0)) then fields:=fields||'["carrier_total"]'::jsonb;end if;
 foreach s in array array['shipments','inbounds','returns','carriers','storage'] loop
 if (s='shipments' and fields ?| array['billable_shipments','shipped_pieces','created_shipments']) or (s='inbounds' and fields ? 'received_pieces') or (s='returns' and fields ? 'billable_returns') or (s='carriers' and fields ? 'carrier_total') or (s='storage' and fields ?| array['billable_m3','stock_pieces']) then sections:=sections||jsonb_build_array(s);end if;
 end loop;
 return jsonb_build_object('source',c.billing_quantity_source,'fields',fields,'sections',sections);
end $$;
CREATE OR REPLACE FUNCTION public.portal_section_snapshot(p_client uuid, p_month date, p_section text, p_start date DEFAULT NULL::date, p_end date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare first_day date:=date_trunc('month',p_month)::date; last_day date:=(date_trunc('month',p_month)+interval '1 month - 1 day')::date; data jsonb; payload jsonb; n integer; missing integer; zero_count integer; stock bigint; stock_date date; average numeric; from_day date:=coalesce(p_start,date_trunc('month',p_month)::date); to_day date:=coalesce(p_end,(date_trunc('month',p_month)+interval '1 month - 1 day')::date);
begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501';end if;
 if p_month is null or p_month<>first_day then raise exception 'Mese non valido';end if;
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
CREATE OR REPLACE FUNCTION public.portal_validate_section(p_client uuid, p_month date, p_section text, p_start date DEFAULT NULL::date, p_end date DEFAULT NULL::date, p_ack_partial boolean DEFAULT false, p_ack_empty boolean DEFAULT false, p_ack_issues boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare snapshot jsonb; preinvoice_error text;
begin
 snapshot:=public.portal_section_snapshot(p_client,p_month,p_section,p_start,p_end);
 if (snapshot->>'rows')::integer=0 and not p_ack_empty then raise exception 'Conferma esplicitamente che non vi è attività per questa sezione';end if;
 if p_section='shipments' and (((public.portal_billing_requirements(p_client,p_month)->'fields') ? 'shipped_pieces' and (snapshot->>'missing_pieces')::integer>0) or ((public.portal_billing_requirements(p_client,p_month)->'fields') ? 'created_shipments' and (snapshot->>'missing_labels')::integer>0)) then raise exception 'Completa i pezzi spediti e le date etichetta importando i file ordini Deagor';end if;
 if p_section='carriers' and (snapshot->>'missing_charges')::integer>0 then raise exception 'Completa gli importi corriere al cliente prima di convalidare';end if;
 if p_section='carriers' and (snapshot->>'unmatched_shipments')::integer>0 and not p_ack_issues then raise exception 'Verifica le spedizioni prive di abbinamento a una fattura corriere';end if;
 if p_section='returns' and (snapshot->>'pending_returns')::integer>0 and not p_ack_issues then raise exception 'Conferma che i resi ancora aperti sono esclusi dal conteggio dei resi gestiti';end if;
 if p_section='storage' and coalesce(snapshot->>'source','deagor')<>'manual' then
 if (snapshot->>'partial')::boolean and not p_ack_partial then raise exception 'Conferma la media sui soli giorni presenti e il periodo di attività';end if;
 if (snapshot->>'zero_volume_skus')::integer>0 and not p_ack_issues then raise exception 'Conferma gli articoli con volume zero';end if;
 if (snapshot->>'rows')::integer=0 then snapshot:=snapshot||jsonb_build_object('billable_m3',0,'stock_pieces',0);end if;
 end if;
 insert into public.portal_section_validations(client_id,month,section,payload) values(p_client,p_month,p_section,snapshot) on conflict(client_id,month,section) do update set payload=excluded.payload,validated_at=now(),validated_by=(select auth.uid());
 update public.portal_months set released=false where client_id=p_client and month=p_month;
 if not exists(select 1 from jsonb_array_elements_text(public.portal_billing_requirements(p_client,p_month)->'sections') s where not exists(select 1 from public.portal_section_validations v where v.client_id=p_client and v.month=p_month and v.section=s)) then
 begin perform public.portal_build_preinvoice(p_client,p_month,false,false);exception when others then preinvoice_error:=SQLERRM;end;
 end if;
 return snapshot||jsonb_build_object('preinvoice_error',preinvoice_error);
end $function$

;
CREATE OR REPLACE FUNCTION public.portal_build_preinvoice(p_client uuid, p_month date, p_confirm boolean DEFAULT false, p_refresh_rates boolean DEFAULT false, p_expected_versions jsonb DEFAULT NULL::jsonb, p_expected_lines jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare validation record; snapshot jsonb; quantities jsonb:='{}'; versions jsonb:='{}'; rates jsonb; lines jsonb:='[]'; r jsonb; q numeric; multiplier integer; price numeric; amount numeric; old_month public.portal_months%rowtype; c public.portal_clients%rowtype; missing integer:=0; space jsonb; minimum_value numeric; logistics_total numeric:=0; logistics_missing boolean:=false; category text; vat_value numeric; net_value numeric; tax_value numeric; transport_data jsonb; transport_record jsonb; carrier_value numeric; requirements jsonb; required_sections jsonb;
begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_client::text||p_month::text,0));
 requirements:=public.portal_billing_requirements(p_client,p_month,p_refresh_rates); required_sections:=requirements->'sections';
 if exists(select 1 from jsonb_array_elements_text(required_sections) s where not exists(select 1 from public.portal_section_validations v where v.client_id=p_client and v.month=p_month and v.section=s)) then raise exception 'Convalida le sezioni previste dalle tariffe prima di preparare la fatturazione';end if;
 for validation in select * from public.portal_section_validations where client_id=p_client and month=p_month and required_sections ? section order by section for update loop
 snapshot:=public.portal_section_snapshot(p_client,p_month,validation.section,(validation.payload->>'period_start')::date,(validation.payload->>'period_end')::date);
 if snapshot->>'signature'<>validation.payload->>'signature' then raise exception 'Dati modificati: riconvalida la sezione %',validation.section;end if;
 if validation.section='shipments' and requirements->>'source'='deagor' and (((requirements->'fields') ? 'shipped_pieces' and (snapshot->>'missing_pieces')::integer>0) or ((requirements->'fields') ? 'created_shipments' and (snapshot->>'missing_labels')::integer>0)) then raise exception 'Completa i dati Deagor richiesti dalle tariffe e riconvalida le spedizioni';end if;
 quantities:=quantities||validation.payload;versions:=versions||jsonb_build_object(validation.section,validation.id::text||'/'||validation.validated_at::text);
 if validation.section='storage' and coalesce(validation.payload->>'source','deagor')<>'manual' then space:=validation.payload;end if;
 end loop;
 select * into c from public.portal_clients where id=p_client;
 select * into old_month from public.portal_months where client_id=p_client and month=p_month for update;
 if old_month.workflow_managed and old_month.invoice_lines is not null and not p_refresh_rates then
 select coalesce(jsonb_agg(value order by ord),'[]') into rates from jsonb_array_elements(old_month.invoice_lines) with ordinality as entries(value,ord) where value->>'basis' not in ('carrier_total','logistics_minimum','transport_charge');
 else rates:=coalesce(c.billing_rules,jsonb_build_array(jsonb_build_object('label','Logistica','basis','billable_shipments','mode','unit','rate',c.logistics_rate),jsonb_build_object('label','Spazio occupato','basis','billable_m3','mode','unit','rate',c.storage_rate),jsonb_build_object('label','Gestione resi','basis','billable_returns','mode','unit','rate',c.return_rate)));end if;
 minimum_value:=case when old_month.workflow_managed and old_month.released and not p_refresh_rates then old_month.minimum_logistics else c.minimum_logistics end;
 vat_value:=case when old_month.workflow_managed and old_month.released and not p_refresh_rates then old_month.vat_rate else c.vat_rate end;
 versions:=versions||jsonb_build_object('minimum_logistics',minimum_value,'vat_rate',vat_value);
 for r in select value from jsonb_array_elements(rates) loop
 category:=coalesce(r->>'category','logistics');if category not in ('logistics','packaging','extra') then raise exception 'Categoria tariffaria non valida';end if;
 multiplier:=coalesce((r->>'multiple')::integer,1);if multiplier<1 then raise exception 'Multipli di deve essere almeno 1';end if;
 if r->>'mode'='included' then q:=0;
 elsif r->>'mode'='fixed' then q:=1;
 elsif r->>'basis'='extra_pieces' then
 q:=(quantities->>'shipped_pieces')::numeric/multiplier-(quantities->>'billable_shipments')::numeric;
 if mod((quantities->>'shipped_pieces')::numeric,multiplier)<>0 then raise exception 'Pezzi spediti non divisibili per il kit da % pezzi',multiplier;end if;
 elsif r->>'basis' in ('shipped_pieces','received_pieces','stock_pieces') then
 q:=(quantities->>(r->>'basis'))::numeric/multiplier;
 if mod((quantities->>(r->>'basis'))::numeric,multiplier)<>0 then raise exception 'Quantità della voce % non divisibile per %',r->>'label',multiplier;end if;
 else q:=(quantities->>(r->>'basis'))::numeric;end if;
 if q is null or q<0 then raise exception 'Quantità non valida per la voce %',r->>'label';end if;
 price:=(r->>'rate')::numeric;if price<0 then raise exception 'Tariffa negativa';end if;
 amount:=case when r->>'mode'='included' or q=0 then 0 else round(q*price,2) end;
 if amount is null then missing:=missing+1;end if;
 if category='logistics' then if amount is null then logistics_missing:=true;else logistics_total:=logistics_total+amount;end if;end if;
 lines:=lines||jsonb_build_array(r||jsonb_build_object('category',category,'multiple',multiplier,'quantity',q,'amount',amount));
 end loop;
 if not logistics_missing and logistics_total<minimum_value then
 amount:=round(minimum_value-logistics_total,2);
 lines:=lines||jsonb_build_array(jsonb_build_object('label','Integrazione al minimo logistico mensile','basis','logistics_minimum','category','logistics','mode','fixed','quantity',1,'rate',amount,'amount',amount,'note','Minimo concordato: '||minimum_value::text||' EUR; servizi logistici: '||logistics_total::text||' EUR'));
 end if;
 carrier_value:=coalesce(round((quantities->>'carrier_total')::numeric,2),0);
 if required_sections ? 'carriers' then
 lines:=lines||jsonb_build_array(jsonb_build_object('label','Trasporti corrieri','basis','carrier_total','category','carriers','mode','fixed','quantity',1,'rate',carrier_value,'amount',carrier_value));
 end if;
 -- Manual pickup transports are reviewed with the final invoice confirmation.
 perform 1 from public.portal_transports where client_id=p_client and transported_on>=p_month and transported_on<p_month+interval '1 month' order by id for share;
 select coalesce(jsonb_agg(to_jsonb(t) order by t.id),'[]') into transport_data from public.portal_transports t where client_id=p_client and transported_on>=p_month and transported_on<p_month+interval '1 month';
 if jsonb_array_length(transport_data)>0 then versions:=versions||jsonb_build_object('transports',md5(transport_data::text));end if;
 for transport_record in select value from jsonb_array_elements(transport_data) loop
 lines:=lines||jsonb_build_array(jsonb_build_object('label',transport_record->>'description','basis','transport_charge','category','transports','transport_id',transport_record->>'id','mode','fixed','multiple',1,'quantity',1,'rate',(transport_record->>'amount')::numeric,'amount',(transport_record->>'amount')::numeric,'note',concat_ws(' · ',to_char((transport_record->>'transported_on')::date,'DD/MM/YYYY'),nullif(transport_record->>'provider',''),case when nullif(transport_record->>'pickup_address','') is not null then 'Ritiro: '||(transport_record->>'pickup_address') end,case when nullif(transport_record->>'delivery_address','') is not null then 'Consegna: '||(transport_record->>'delivery_address') end,case when nullif(transport_record->>'reference','') is not null then 'Rif. '||(transport_record->>'reference') end,nullif(transport_record->>'notes',''))));
 end loop;
 if p_confirm and (p_expected_versions is null or versions<>p_expected_versions or p_expected_lines is null or old_month.invoice_lines<>p_expected_lines or lines<>p_expected_lines or old_month.minimum_logistics<>minimum_value) then raise exception 'Prefattura modificata: aggiorna e ricontrolla il dettaglio prima della conferma';end if;
 select sum((value->>'amount')::numeric) into net_value from jsonb_array_elements(lines);
 if missing>0 then net_value:=null;end if;
 tax_value:=round(net_value*vat_value/100,2);
 if p_confirm and vat_value is null then raise exception 'Imposta l’aliquota IVA nella scheda cliente prima della conferma finale';end if;
 if p_confirm and missing>0 then raise exception 'Completa le tariffe applicate prima della conferma finale';end if;
 perform set_config('portal.workflow_confirmation','true',true);
 insert into public.portal_months(client_id,month,billable_shipments,shipped_pieces,received_pieces,stock_pieces,created_shipments,billable_returns,billable_m3,logistics_rate,storage_rate,return_rate,storage_basis,invoice_lines,carrier_total,storage_scope,validation_versions,workflow_managed,released,minimum_logistics,vat_rate,vat_amount,invoice_total)
 values(p_client,p_month,(quantities->>'billable_shipments')::integer,(quantities->>'shipped_pieces')::bigint,(quantities->>'received_pieces')::bigint,(quantities->>'stock_pieces')::bigint,(quantities->>'created_shipments')::bigint,(quantities->>'billable_returns')::integer,(quantities->>'billable_m3')::numeric,c.logistics_rate,c.storage_rate,c.return_rate,'validated_average',lines,carrier_value,space,versions,true,p_confirm,minimum_value,vat_value,tax_value,net_value+tax_value)
 on conflict(client_id,month) do update set billable_shipments=excluded.billable_shipments,shipped_pieces=excluded.shipped_pieces,received_pieces=excluded.received_pieces,stock_pieces=excluded.stock_pieces,created_shipments=excluded.created_shipments,billable_returns=excluded.billable_returns,billable_m3=excluded.billable_m3,storage_basis=excluded.storage_basis,invoice_lines=excluded.invoice_lines,carrier_total=excluded.carrier_total,storage_scope=excluded.storage_scope,validation_versions=excluded.validation_versions,workflow_managed=true,released=p_confirm,minimum_logistics=excluded.minimum_logistics,vat_rate=excluded.vat_rate,vat_amount=excluded.vat_amount,invoice_total=excluded.invoice_total;
 return jsonb_build_object('lines',lines,'missing_rates',missing,'confirmed',p_confirm,'vat_rate',vat_value,'vat_amount',tax_value,'invoice_total',net_value+tax_value);
end $function$

;

create or replace function public.portal_validate_manual_section(p_client uuid,p_month date,p_section text,p_quantities jsonb,p_ack_empty boolean default false)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare req jsonb; allowed_fields text[]; f text; value numeric; clean jsonb:='{}'; needed integer:=0;
begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_client::text||p_month::text,0));
 if p_month is null or p_month<>date_trunc('month',p_month)::date then raise exception 'Mese non valido';end if;
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
end $$;
revoke all on function public.portal_billing_requirements(uuid,date,boolean) from public,anon;
revoke all on function public.portal_validate_manual_section(uuid,date,text,jsonb,boolean) from public,anon;
grant execute on function public.portal_billing_requirements(uuid,date,boolean) to authenticated;
grant execute on function public.portal_validate_manual_section(uuid,date,text,jsonb,boolean) to authenticated;
-- User identified this customer as externally counted; tariffs and past invoices are unchanged.
update public.portal_clients set billing_quantity_source='manual' where id='84e2e54b-935d-476d-98a8-c7f5bae716d5' and name='JAPANDEALSTORE SRLS';
-- Direct edits of a manual count also invalidate its review and monthly draft.
create or replace function public.portal_manual_billing_invalidate() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if TG_OP in ('UPDATE','DELETE') then
 delete from public.portal_section_validations where client_id=old.client_id and month=old.month and section=old.section;
 update public.portal_months set released=false where client_id=old.client_id and month=old.month;
 end if;
 if TG_OP in ('INSERT','UPDATE') then
 delete from public.portal_section_validations where client_id=new.client_id and month=new.month and section=new.section;
 update public.portal_months set released=false where client_id=new.client_id and month=new.month;
 end if;
 return null;
end $$;
revoke all on function public.portal_manual_billing_invalidate() from public,anon;
create trigger manual_billing_changed after insert or update or delete on public.portal_manual_billing_quantities for each row execute function public.portal_manual_billing_invalidate();
-- Switching to current tariffs must expose any newly required quantity, even if its section was absent in the old draft.
create or replace function public.portal_refresh_billing_rates(p_client uuid,p_month date) returns jsonb language plpgsql security invoker set search_path='' as $$
declare c public.portal_clients%rowtype; rates jsonb; result jsonb;
begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_client::text||p_month::text,0));
 select * into c from public.portal_clients where id=p_client;
 if not found then raise exception 'Cliente non trovato';end if;
 rates:=coalesce(c.billing_rules,jsonb_build_array(jsonb_build_object('label','Logistica','basis','billable_shipments','mode','unit','rate',c.logistics_rate),jsonb_build_object('label','Spazio occupato','basis','billable_m3','mode','unit','rate',c.storage_rate),jsonb_build_object('label','Gestione resi','basis','billable_returns','mode','unit','rate',c.return_rate)));
 select coalesce(jsonb_agg((r-'quantity'-'amount')||jsonb_build_object('quantity',null,'amount',null)),'[]') into rates from jsonb_array_elements(rates) r;
 update public.portal_months set invoice_lines=rates,released=false,validation_versions='{}',vat_amount=null,invoice_total=null where client_id=p_client and month=p_month;
 begin result:=public.portal_build_preinvoice(p_client,p_month,false,true);
 exception when others then result:=jsonb_build_object('preinvoice_error',SQLERRM);
 end;
 return result;
end $$;
revoke all on function public.portal_refresh_billing_rates(uuid,date) from public,anon;
grant execute on function public.portal_refresh_billing_rates(uuid,date) to authenticated;

commit;
