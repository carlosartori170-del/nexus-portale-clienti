-- Solo dopo approvazione: aggiorna la voce dal secondo prodotto di OPTIC LUXE.
-- Guardia contro modifiche concorrenti; nessuna prefattura o fattura viene ricalcolata.
do $config$
declare changed integer;
begin
 update public.portal_clients
 set billing_rules=$next$[{"mode":"unit","note":"","rate":2.15,"basis":"billable_shipments","label":"Logistica 1° prodotto","multiple":5},{"mode":"unit","note":"","rate":25,"basis":"billable_m3","label":"Spazio occupato"},{"mode":"unit","note":"","rate":1.5,"basis":"billable_returns","label":"Gestione resi","multiple":5},{"mode":"unit","note":"","rate":0.85,"basis":"extra_pieces","label":"Logistica dal 2° prodotto","category":"logistics","multiple":4,"per_order_pieces":1}]$next$::jsonb
 where id='d592acee-716e-4601-a9e5-bebf105c8c01' and name='OPTIC LUXE'
 and billing_rules=$previous$[{"mode":"unit","note":"","rate":2.15,"basis":"billable_shipments","label":"Logistica 1° prodotto","multiple":5},{"mode":"unit","note":"","rate":25,"basis":"billable_m3","label":"Spazio occupato"},{"mode":"unit","note":"","rate":1.5,"basis":"billable_returns","label":"Gestione resi","multiple":5},{"mode":"unit","note":"","rate":0.85,"basis":"extra_pieces","label":"Logistica dal 2° prodotto","category":"logistics","multiple":5}]$previous$::jsonb;
 get diagnostics changed=row_count;
 if changed<>1 then raise exception 'Tariffe OPTIC LUXE modificate: rileggere prima di applicare';end if;
end $config$;
