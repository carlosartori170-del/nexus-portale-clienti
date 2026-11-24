-- Tariff plans and chosen tiers are stored in existing JSON tariff snapshots.
-- No table, RLS policy, or saved client/month data is replaced by this DDL.
create function public.portal_check_shipment_tiers(p_tiers jsonb) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare tier jsonb; expected_min bigint:=0; lo bigint; hi bigint; price numeric;
begin
 if p_tiers is null or jsonb_typeof(p_tiers)<>'array' then raise exception 'Inserisci gli scaglioni del canone';end if;
 if jsonb_array_length(p_tiers)<1 or jsonb_array_length(p_tiers)>50 then raise exception 'Configura da 1 a 50 scaglioni';end if;
 for tier in select value from jsonb_array_elements(p_tiers) loop
  if coalesce(tier->>'min','')!~'^\d+$' or coalesce(tier->>'max','')!~'^\d+$'
    or coalesce(tier->>'rate','')!~'^\d+(\.\d{1,2})?$' then raise exception 'Soglie intere e canoni non negativi con massimo due decimali';end if;
  lo:=(tier->>'min')::bigint;hi:=(tier->>'max')::bigint;price:=(tier->>'rate')::numeric;
  if lo<>expected_min or hi<lo or hi>2147483647 or price>999999999999.99 then
   raise exception 'Le fasce devono partire da zero ed essere consecutive, senza vuoti o sovrapposizioni';
  end if;
  expected_min:=hi+1;
 end loop;
 return p_tiers;
end $$;
revoke all on function public.portal_check_shipment_tiers(jsonb) from public,anon;
grant execute on function public.portal_check_shipment_tiers(jsonb) to authenticated;

create function public.portal_set_shipment_tier_plan(p_client uuid,p_label text,p_tiers jsonb,p_note text,p_expected_rules jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare c public.portal_clients%rowtype; plan jsonb;
begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501';end if;
 perform public.portal_check_shipment_tiers(p_tiers);
 if length(trim(coalesce(p_label,''))) not between 1 and 200 or length(coalesce(p_note,''))>2000 then raise exception 'Descrizione o condizioni del canone non valide';end if;
 select * into c from public.portal_clients where id=p_client for update;
 if not found then raise exception 'Cliente non trovato';end if;
 if c.billing_rules is distinct from p_expected_rules then raise exception 'Tariffe modificate: riapri la configurazione';end if;
 if c.billing_rules is null or jsonb_array_length(c.billing_rules)<>1 or c.billing_rules->0->>'basis'<>'billable_shipments'
   or coalesce(c.billing_rules->0->>'category','logistics')<>'logistics' then
  raise exception 'Il canone a scaglioni richiede una sola voce logistica basata sulle spedizioni';
 end if;
 plan:=jsonb_build_array(jsonb_build_object('label',trim(p_label),'basis','billable_shipments','category','logistics','mode','tiered','rate',null,'multiple',1,'per_order_pieces',0,'tiers',p_tiers,'tier_base_note',trim(coalesce(p_note,'')),'note',trim(coalesce(p_note,''))));
 update public.portal_clients set billing_rules=plan where id=p_client;
 return plan;
end $$;
revoke all on function public.portal_set_shipment_tier_plan(uuid,text,jsonb,text,jsonb) from public,anon;
grant execute on function public.portal_set_shipment_tier_plan(uuid,text,jsonb,text,jsonb) to authenticated;

create function public.portal_select_shipment_tier(p_client uuid,p_month date,p_rule_index integer,p_tier_index integer,p_expected_lines jsonb,p_expected_versions jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare m public.portal_months%rowtype; v public.portal_section_validations%rowtype; rule jsonb; tier jsonb; current_data jsonb; choice jsonb; count_value integer;
begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501';end if;
 if p_month is null or p_month<>date_trunc('month',p_month)::date then raise exception 'Mese non valido';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_client::text||p_month::text,0));
 if not public.portal_client_active_in_month(p_client,p_month) then raise exception 'Cliente non attivo nel mese selezionato';end if;
 select * into m from public.portal_months where client_id=p_client and month=p_month for update;
 if not found or not m.workflow_managed then raise exception 'Convalida le spedizioni e prepara prima la prefattura';end if;
 if p_expected_lines is null or m.invoice_lines is distinct from p_expected_lines or p_expected_versions is null or m.validation_versions is distinct from p_expected_versions then
  raise exception 'Prefattura modificata: aggiorna la pagina e riapri gli scaglioni';
 end if;
 if p_rule_index is null or p_rule_index<0 or p_rule_index>=jsonb_array_length(m.invoice_lines) then raise exception 'Voce del canone non valida';end if;
 rule:=m.invoice_lines->p_rule_index;
 if rule->>'mode'<>'tiered' or rule->>'basis'<>'billable_shipments' then raise exception 'Voce non configurata per canone a scaglioni';end if;
 perform public.portal_check_shipment_tiers(rule->'tiers');
 if p_tier_index is null or p_tier_index<0 or p_tier_index>=jsonb_array_length(rule->'tiers') then raise exception 'Seleziona uno scaglione valido';end if;
 select * into v from public.portal_section_validations where client_id=p_client and month=p_month and section='shipments' for share;
 if not found then raise exception 'Convalida prima le spedizioni del mese';end if;
 current_data:=public.portal_section_snapshot(p_client,p_month,'shipments');
 if current_data->>'signature' is distinct from v.payload->>'signature' then raise exception 'Spedizioni modificate: riconvalida prima di scegliere lo scaglione';end if;
 count_value:=(current_data->>'billable_shipments')::integer;
 tier:=rule->'tiers'->p_tier_index;
 if count_value is null or count_value<(tier->>'min')::integer or count_value>(tier->>'max')::integer then raise exception 'Lo scaglione scelto non comprende le % spedizioni convalidate',count_value;end if;
 choice:=jsonb_build_object('index',p_tier_index,'shipments',count_value,'signature',current_data->>'signature','selected_at',clock_timestamp(),'selected_by',auth.uid());
 update public.portal_months set released=false,invoice_lines=jsonb_set(invoice_lines,array[p_rule_index::text],rule||jsonb_build_object('selected_tier',choice)) where id=m.id;
 -- Rechecks all sections and recalculates minimum, discount, VAT and totals atomically.
 return public.portal_build_preinvoice(p_client,p_month,false,false);
end $$;
revoke all on function public.portal_select_shipment_tier(uuid,date,integer,integer,jsonb,jsonb) from public,anon;
grant execute on function public.portal_select_shipment_tier(uuid,date,integer,integer,jsonb,jsonb) to authenticated;
