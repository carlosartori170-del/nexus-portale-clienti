-- Synthetic tariff values. Run after both DDL files in BEGIN ... ROLLBACK.
do $claims$ begin perform set_config('request.jwt.claim.sub',(select user_id::text from public.portal_admins order by user_id limit 1),true);end $claims$;
set local role authenticated;
do $test$
declare cid uuid; tiers jsonb:='[{"min":0,"max":100,"rate":100},{"min":101,"max":150,"rate":200},{"min":151,"max":200,"rate":300},{"min":201,"max":250,"rate":400}]';
 old_rules jsonb; current_rules jsonb; m public.portal_months%rowtype; response jsonb; snap jsonb; failed boolean; i integer; qty integer; chosen integer; fee numeric; month_value date; claim text; history_hash text; source_id uuid; old_lines jsonb;
begin
 claim:=current_setting('request.jwt.claim.sub');
 insert into public.portal_clients(name,billing_quantity_source,billing_daily_shipments,billing_rules,minimum_logistics,vat_rate)
 values('Test scaglioni spedizioni '||gen_random_uuid(),'manual',true,'[{"label":"Logistica","basis":"billable_shipments","mode":"unit","rate":2,"category":"logistics"}]',0,22) returning id into cid;
 select billing_rules into old_rules from public.portal_clients where id=cid;
 current_rules:=public.portal_set_shipment_tier_plan(cid,'Preparazione',tiers,'Trasporto escluso',old_rules);
 failed:=false;begin perform public.portal_set_shipment_tier_plan(cid,'Preparazione',tiers,'',old_rules);exception when others then failed:=sqlerrm like 'Tariffe modificate:%';end;assert failed,'Stale plan edit accepted';
 failed:=false;begin perform public.portal_check_shipment_tiers('[{"min":0,"max":100,"rate":10},{"min":100,"max":150,"rate":20}]');exception when others then failed:=true;end;assert failed,'Overlapping tiers accepted';
 failed:=false;begin perform public.portal_check_shipment_tiers('[{"min":1,"max":100,"rate":10}]');exception when others then failed:=true;end;assert failed,'Missing zero tier accepted';
 failed:=false;begin perform public.portal_check_shipment_tiers('[{"min":0,"max":100,"rate":10.001}]');exception when others then failed:=true;end;assert failed,'Excess price precision accepted';
 for i in 1..8 loop
  qty:=(array[0,100,101,150,151,200,201,250])[i];chosen:=(array[0,0,1,1,2,2,3,3])[i];fee:=(chosen+1)*100;
  month_value:=make_date(2099,i,1);
  insert into public.portal_daily_dispatches(client_id,shipped_on,received_on,supplier,piece_count,shipment_count)
  values(cid,month_value,month_value,'Fornitore test',qty,qty);
  response:=public.portal_validate_section(cid,month_value,'shipments',null,null,false,qty=0,false);assert response->>'preinvoice_error' is null,'Validation failed';
  select * into m from public.portal_months where client_id=cid and month=month_value;
  assert m.invoice_lines->0->>'quantity'='1' and m.invoice_lines->0->>'amount' is null,'Unselected tier was billed automatically';
  assert public.portal_billing_requirements(cid,month_value)->'fields'='["billable_shipments"]'::jsonb,'Tier did not require shipment validation';
  failed:=false;begin perform public.portal_select_shipment_tier(cid,month_value,0,(chosen+1)%4,m.invoice_lines,m.validation_versions);exception when others then failed:=sqlerrm like 'Lo scaglione scelto non comprende%';end;assert failed,'Out-of-band selection accepted';
  response:=public.portal_select_shipment_tier(cid,month_value,0,chosen,m.invoice_lines,m.validation_versions);
  select * into m from public.portal_months where client_id=cid and month=month_value;
  assert (m.invoice_lines->0->>'quantity')::numeric=1 and (m.invoice_lines->0->>'rate')::numeric=fee and (m.invoice_lines->0->>'amount')::numeric=fee,'Canone multiplied by shipment count';
  assert m.invoice_total=round(fee*1.22,2),'VAT or total incorrect';
  response:=public.portal_build_preinvoice(cid,month_value,true,false,m.validation_versions,m.invoice_lines);
  snap:=public.portal_invoice_snapshot(m.id,'TEST-TIER-'||i,month_value,month_value,'Bonifico','',true);
  assert snap->'lines'->0->>'quantity'='1' and (snap->'lines'->0->>'amount')::numeric=fee,'PDF snapshot lost fixed tier amount';
  assert snap->'lines'->0->>'note' like '%effettive: '||qty::text,'Actual shipments missing from invoice condition';
 end loop;
 -- Overflow: no extrapolation beyond the configured table.
 insert into public.portal_daily_dispatches(client_id,shipped_on,received_on,supplier,piece_count,shipment_count) values(cid,'2099-09-01','2099-09-01','Fornitore test',251,251);
 response:=public.portal_validate_section(cid,'2099-09-01','shipments');
 select * into m from public.portal_months where client_id=cid and month='2099-09-01';
 assert m.invoice_total is null;
 failed:=false;begin perform public.portal_select_shipment_tier(cid,'2099-09-01',0,3,m.invoice_lines,m.validation_versions);exception when others then failed:=sqlerrm like 'Lo scaglione scelto non comprende%';end;assert failed,'Overflow was assigned last fee';
 failed:=false;begin perform public.portal_build_preinvoice(cid,'2099-09-01',true,false,m.validation_versions,m.invoice_lines);exception when others then failed:=true;end;assert failed,'Unselected tier final confirmation accepted';
 -- Changing data inside the SAME band still requires a fresh explicit choice.
 update public.portal_daily_dispatches set notes='Correzione di prova' where client_id=cid and shipped_on='2099-02-01';
 response:=public.portal_validate_section(cid,'2099-02-01','shipments');
 select * into m from public.portal_months where client_id=cid and month='2099-02-01';
 assert not m.released and m.invoice_total is null,'Stale tier confirmation reused';
 old_lines:=m.invoice_lines;
 response:=public.portal_select_shipment_tier(cid,'2099-02-01',0,0,m.invoice_lines,m.validation_versions);
 failed:=false;begin perform public.portal_select_shipment_tier(cid,'2099-02-01',0,0,old_lines,m.validation_versions);exception when others then failed:=sqlerrm like 'Prefattura modificata:%';end;assert failed,'Stale preinvoice accepted';
 -- Future tariff edits preserve every saved month, including confirmed snapshots.
 select md5(jsonb_agg(to_jsonb(x) order by x.id)::text) into history_hash from public.portal_months x where client_id=cid;
 current_rules:=public.portal_set_shipment_tier_plan(cid,'Preparazione aggiornata',jsonb_set(tiers,'{0,rate}','110'),'Nuove condizioni',current_rules);
 assert history_hash=(select md5(jsonb_agg(to_jsonb(x) order by x.id)::text) from public.portal_months x where client_id=cid),'Plan edit changed saved billing months';
 select * into m from public.portal_months where client_id=cid and month='2099-01-01';
 assert (m.invoice_lines->0->>'rate')::numeric=100 and m.released,'Old tariff snapshot overwritten';
 -- Existing refresh action opts a draft month into the current plan, never auto-selects it.
 response:=public.portal_refresh_billing_rates(cid,'2099-02-01');assert response->>'preinvoice_error' is null;
 select * into m from public.portal_months where client_id=cid and month='2099-02-01';
 assert m.invoice_lines->0->'selected_tier' is null and m.invoice_total is null;
 response:=public.portal_select_shipment_tier(cid,'2099-02-01',0,0,m.invoice_lines,m.validation_versions);
 select * into m from public.portal_months where client_id=cid and month='2099-02-01';assert m.invoice_total=134.20;
 -- Ordinary discount logic still runs AFTER the selected canone.
 response:=public.portal_set_invoice_discount(cid,'2099-02-01',10,'Accordo test',m.invoice_lines,null);assert (response->>'invoice_total')::numeric=122;
 perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 failed:=false;begin perform public.portal_select_shipment_tier(cid,'2099-02-01',0,0,m.invoice_lines,m.validation_versions);exception when insufficient_privilege then failed:=true;end;assert failed,'Non-admin selection accepted';
 perform set_config('request.jwt.claim.sub',claim,true);
 assert not has_function_privilege('anon','public.portal_select_shipment_tier(uuid,date,integer,integer,jsonb,jsonb)','EXECUTE');
 assert not has_function_privilege('anon','public.portal_set_shipment_tier_plan(uuid,text,jsonb,text,jsonb)','EXECUTE');
end $test$;
reset role;
select 'Scaglioni: confini inclusivi, zero, canone fisso, IVA, snapshot PDF, scelta obbligatoria, modifiche, storico, refresh, sconto e permessi superati' as esito;
