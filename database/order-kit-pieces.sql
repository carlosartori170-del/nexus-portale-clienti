-- Approvazione richiesta prima dell’applicazione in produzione.
-- Aggiorna soltanto il calcolo tariffario; non ricalcola mesi o documenti salvati.
-- Pezzi fissi per ordine: sottratti prima di convertire i pezzi in prodotti.
create or replace function public.portal_tariff_quantity(p_quantities jsonb,p_rule jsonb)
returns numeric language plpgsql immutable security invoker set search_path=''
as $kit$
declare
 basis text:=p_rule->>'basis';
 divisor numeric:=coalesce((p_rule->>'multiple')::numeric,1);
 fixed numeric:=coalesce((p_rule->>'per_order_pieces')::numeric,0);
 q numeric; orders numeric;
begin
 if divisor<1 or divisor<>trunc(divisor) then raise exception 'Multipli di deve essere un intero positivo';end if;
 if fixed<0 or fixed<>trunc(fixed) then raise exception 'Pezzi fissi per ordine non validi';end if;
 if fixed>0 and basis not in ('extra_pieces','shipped_pieces') then raise exception 'I pezzi fissi per ordine si applicano solo ai pezzi spediti';end if;
 if p_rule->>'mode'='included' then return 0;end if;
 if p_rule->>'mode'='fixed' then return 1;end if;
 q:=(p_quantities->>(case when basis='extra_pieces' then 'shipped_pieces' else basis end))::numeric;
 if q is null then return null;end if;
 if q<0 then raise exception 'Quantità non valida';end if;
 if fixed>0 or basis='extra_pieces' then
  orders:=(p_quantities->>'billable_shipments')::numeric;
  if orders is null then return null;end if;
  if orders<0 or orders<>trunc(orders) then raise exception 'Numero ordini non valido';end if;
 end if;
 if fixed>0 then
  q:=q-fixed*orders;
  if q<0 then raise exception 'Pezzi inferiori ai pezzi fissi previsti per gli ordini';end if;
 end if;
 if basis in ('extra_pieces','shipped_pieces','received_pieces','stock_pieces') then
  if mod(q,divisor)<>0 then raise exception 'Quantità non divisibile per il kit da % pezzi dopo l’esclusione dei pezzi fissi per ordine',divisor;end if;
  q:=q/divisor;
 end if;
 if basis='extra_pieces' then q:=q-orders;end if;
 if q<0 then raise exception 'I prodotti spediti non possono essere inferiori agli ordini spediti';end if;
 return q;
end $kit$;
revoke all on function public.portal_tariff_quantity(jsonb,jsonb) from public,anon;
grant execute on function public.portal_tariff_quantity(jsonb,jsonb) to authenticated;

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
 foreach s in array array['shipments','inbounds','returns','carriers','storage'] loop
 if (s='shipments' and fields ?| array['billable_shipments','shipped_pieces','created_shipments']) or (s='inbounds' and fields ? 'received_pieces') or (s='returns' and fields ? 'billable_returns') or (s='carriers' and fields ? 'carrier_total') or (s='storage' and fields ?| array['billable_m3','stock_pieces']) then sections:=sections||jsonb_build_array(s);end if;
 end loop;
 return jsonb_build_object('source',c.billing_quantity_source,'fields',fields,'sections',sections);
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
 q:=public.portal_tariff_quantity(quantities,r);
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
