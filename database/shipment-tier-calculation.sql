do $guard$ begin
 if md5(pg_get_functiondef('public.portal_build_preinvoice(uuid,date,boolean,boolean,jsonb,jsonb)'::regprocedure))<>'2542611bfbb62ef92d4b26e1d37a470b' then raise exception 'Il calcolo fatture è cambiato: verificare la migrazione prima di applicarla';end if;
end $guard$;

CREATE OR REPLACE FUNCTION public.portal_build_preinvoice(p_client uuid, p_month date, p_confirm boolean DEFAULT false, p_refresh_rates boolean DEFAULT false, p_expected_versions jsonb DEFAULT NULL::jsonb, p_expected_lines jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare validation record; snapshot jsonb; quantities jsonb:='{}'; versions jsonb:='{}'; rates jsonb; lines jsonb:='[]'; r jsonb; q numeric; multiplier integer; price numeric; amount numeric; old_month public.portal_months%rowtype; c public.portal_clients%rowtype; missing integer:=0; space jsonb; minimum_value numeric; logistics_total numeric:=0; logistics_missing boolean:=false; category text; vat_value numeric; net_value numeric; tax_value numeric; transport_data jsonb; transport_record jsonb; carrier_value numeric; requirements jsonb; required_sections jsonb; discount_data jsonb; discount_value numeric; tier jsonb; choice jsonb; tier_count integer; tier_index integer; tier_valid boolean; tier_note text;
begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501';end if;
 if not public.portal_client_active_in_month(p_client,p_month) then raise exception 'Cliente non attivo nel mese selezionato: controlla il periodo di gestione nella scheda cliente';end if;
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
 select coalesce(jsonb_agg(value order by ord),'[]') into rates from jsonb_array_elements(old_month.invoice_lines) with ordinality as entries(value,ord) where value->>'basis' not in ('carrier_total','logistics_minimum','transport_charge','invoice_discount');
 else rates:=coalesce(c.billing_rules,jsonb_build_array(jsonb_build_object('label','Logistica','basis','billable_shipments','mode','unit','rate',c.logistics_rate),jsonb_build_object('label','Spazio occupato','basis','billable_m3','mode','unit','rate',c.storage_rate),jsonb_build_object('label','Gestione resi','basis','billable_returns','mode','unit','rate',c.return_rate)));end if;
 minimum_value:=case when old_month.workflow_managed and old_month.released and not p_refresh_rates then old_month.minimum_logistics else c.minimum_logistics end;
 vat_value:=case when old_month.workflow_managed and old_month.released and not p_refresh_rates then old_month.vat_rate else c.vat_rate end;
 versions:=versions||jsonb_build_object('minimum_logistics',minimum_value,'vat_rate',vat_value);
 for r in select value from jsonb_array_elements(rates) loop
 category:=coalesce(r->>'category','logistics');if category not in ('logistics','packaging','extra') then raise exception 'Categoria tariffaria non valida';end if;
 multiplier:=coalesce((r->>'multiple')::integer,1);if multiplier<1 then raise exception 'Multipli di deve essere almeno 1';end if;
 if r->>'mode'='tiered' then
  if r->>'basis'<>'billable_shipments' or category<>'logistics' then raise exception 'Canone a scaglioni valido solo per spedizioni logistiche';end if;
  perform public.portal_check_shipment_tiers(r->'tiers');
  q:=1;price:=null;tier_valid:=false;tier_count:=(quantities->>'billable_shipments')::integer;
  choice:=r->'selected_tier';tier_index:=(choice->>'index')::integer;
  if tier_index>=0 and tier_index<jsonb_array_length(r->'tiers') then
   tier:=r->'tiers'->tier_index;
   select payload->>'signature' into tier_note from public.portal_section_validations where client_id=p_client and month=p_month and section='shipments';
   tier_valid:=coalesce(tier_count=(choice->>'shipments')::integer and tier_note=choice->>'signature' and tier_count between (tier->>'min')::integer and (tier->>'max')::integer,false);
   if tier_valid then price:=(tier->>'rate')::numeric;end if;
  end if;
  tier_note:=coalesce(r->>'tier_base_note',r->>'note','');
  r:=r||jsonb_build_object('tier_base_note',tier_note,'rate',price,'note',concat_ws(' · ',nullif(tier_note,''),case when tier_valid then 'Canone mensile fascia '||(tier->>'min')||'–'||(tier->>'max')||' spedizioni; effettive: '||tier_count::text else 'Scaglione da scegliere e confermare per '||coalesce(tier_count::text,'—')||' spedizioni' end));
 else
  q:=public.portal_tariff_quantity(quantities,r);
  price:=(r->>'rate')::numeric;
 end if;
 if q is null or q<0 then raise exception 'Quantità non valida per la voce %',r->>'label';end if;
 if price<0 then raise exception 'Tariffa negativa';end if;
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
 -- Lo sconto è applicato dopo minimo logistico e tutti i servizi/corrieri.
 select to_jsonb(d) into discount_data from public.portal_invoice_discounts d where client_id=p_client and month=p_month for share;
 discount_value:=coalesce((discount_data->>'amount')::numeric,0);
 if discount_value>0 then
  select sum((value->>'amount')::numeric) into net_value from jsonb_array_elements(lines);
  if missing>0 or net_value is null then raise exception 'Completa tutte le tariffe prima di applicare lo sconto';end if;
  if discount_value>net_value then raise exception 'Lo sconto non può superare l’imponibile prima dello sconto (%)',net_value;end if;
  lines:=lines||jsonb_build_array(jsonb_build_object('label','Sconto concordato','basis','invoice_discount','category','discount','mode','fixed','quantity',1,'rate',-discount_value,'amount',-discount_value,'note',discount_data->>'description'));
  versions:=versions||jsonb_build_object('invoice_discount',md5(discount_data::text));
 end if;
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

