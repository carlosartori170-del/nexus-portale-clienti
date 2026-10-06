alter table public.portal_clients add column minimum_logistics numeric(12,2) not null default 0 check(minimum_logistics>=0);
alter table public.portal_months add column minimum_logistics numeric(12,2) not null default 0 check(minimum_logistics>=0);
create or replace function public.portal_build_preinvoice(p_client uuid,p_month date,p_confirm boolean default false,p_refresh_rates boolean default false,p_expected_versions jsonb default null,p_expected_lines jsonb default null) returns jsonb language plpgsql security invoker set search_path='' as $$
declare validation record; snapshot jsonb; quantities jsonb:='{}'; versions jsonb:='{}'; rates jsonb; lines jsonb:='[]'; r jsonb; q numeric; multiplier integer; price numeric; amount numeric; old_month public.portal_months%rowtype; c public.portal_clients%rowtype; missing integer:=0; space jsonb; minimum_value numeric; logistics_total numeric:=0; logistics_missing boolean:=false; category text;
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
 select coalesce(jsonb_agg(value order by ord),'[]') into rates from jsonb_array_elements(old_month.invoice_lines) with ordinality as entries(value,ord) where value->>'basis' not in ('carrier_total','logistics_minimum');
 else rates:=coalesce(c.billing_rules,jsonb_build_array(jsonb_build_object('label','Logistica','basis','billable_shipments','mode','unit','rate',c.logistics_rate),jsonb_build_object('label','Spazio occupato','basis','billable_m3','mode','unit','rate',c.storage_rate),jsonb_build_object('label','Gestione resi','basis','billable_returns','mode','unit','rate',c.return_rate)));end if;
 minimum_value:=case when old_month.workflow_managed and not p_refresh_rates then old_month.minimum_logistics else c.minimum_logistics end;
 for r in select value from jsonb_array_elements(rates) loop
 category:=coalesce(r->>'category','logistics');if category not in ('logistics','packaging','extra') then raise exception 'Categoria tariffaria non valida';end if;
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
 if category='logistics' then if amount is null then logistics_missing:=true;else logistics_total:=logistics_total+amount;end if;end if;
 lines:=lines||jsonb_build_array(r||jsonb_build_object('category',category,'multiple',multiplier,'quantity',q,'amount',amount));
 end loop;
 if not logistics_missing and logistics_total<minimum_value then
 amount:=round(minimum_value-logistics_total,2);
 lines:=lines||jsonb_build_array(jsonb_build_object('label','Integrazione al minimo logistico mensile','basis','logistics_minimum','category','logistics','mode','fixed','quantity',1,'rate',amount,'amount',amount,'note','Minimo concordato: '||minimum_value::text||' EUR; servizi logistici: '||logistics_total::text||' EUR'));
 end if;
 amount:=round((quantities->>'carrier_total')::numeric,2);
 lines:=lines||jsonb_build_array(jsonb_build_object('label','Trasporti corrieri','basis','carrier_total','category','carriers','mode','fixed','quantity',1,'rate',amount,'amount',amount));
 if p_confirm and (p_expected_versions is null or versions<>p_expected_versions or p_expected_lines is null or old_month.invoice_lines<>p_expected_lines or old_month.minimum_logistics<>minimum_value) then raise exception 'Prefattura modificata: aggiorna e ricontrolla il dettaglio prima della conferma';end if;
 if p_confirm and missing>0 then raise exception 'Completa le tariffe applicate prima della conferma finale';end if;
 perform set_config('portal.workflow_confirmation','true',true);
 insert into public.portal_months(client_id,month,billable_shipments,shipped_pieces,received_pieces,stock_pieces,created_shipments,billable_returns,billable_m3,logistics_rate,storage_rate,return_rate,storage_basis,invoice_lines,carrier_total,storage_scope,validation_versions,workflow_managed,released,minimum_logistics)
 values(p_client,p_month,(quantities->>'billable_shipments')::integer,(quantities->>'shipped_pieces')::bigint,(quantities->>'received_pieces')::bigint,(quantities->>'stock_pieces')::bigint,(quantities->>'created_shipments')::bigint,(quantities->>'billable_returns')::integer,(quantities->>'billable_m3')::numeric,c.logistics_rate,c.storage_rate,c.return_rate,'validated_average',lines,amount,space,versions,true,p_confirm,minimum_value)
 on conflict(client_id,month) do update set billable_shipments=excluded.billable_shipments,shipped_pieces=excluded.shipped_pieces,received_pieces=excluded.received_pieces,stock_pieces=excluded.stock_pieces,created_shipments=excluded.created_shipments,billable_returns=excluded.billable_returns,billable_m3=excluded.billable_m3,storage_basis=excluded.storage_basis,invoice_lines=excluded.invoice_lines,carrier_total=excluded.carrier_total,storage_scope=excluded.storage_scope,validation_versions=excluded.validation_versions,workflow_managed=true,released=p_confirm,minimum_logistics=excluded.minimum_logistics;
 return jsonb_build_object('lines',lines,'missing_rates',missing,'confirmed',p_confirm);
end $$;
revoke all on function public.portal_build_preinvoice(uuid,date,boolean,boolean,jsonb,jsonb) from public,anon;
grant execute on function public.portal_build_preinvoice(uuid,date,boolean,boolean,jsonb,jsonb) to authenticated;
