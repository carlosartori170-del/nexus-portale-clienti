-- Eseguire dopo la migrazione. Solo fixture sintetiche, rollback completo.
begin;
do $claims$ begin perform set_config('request.jwt.claim.sub','c1471010-7afd-4f5f-98b1-04006d7943bc',true);end $claims$;
set local role authenticated;
do $test$
declare c uuid; m uuid; s jsonb; rejected boolean;
begin
insert into public.portal_clients(name,billing_rules) values('Test arrotondamento spazio '||gen_random_uuid(),'[]') returning id into c;
perform set_config('portal.workflow_confirmation','true',true);
insert into public.portal_months(client_id,month,workflow_managed,released,invoice_lines,vat_rate,minimum_logistics) values(c,'2099-11-01',true,true,'[{"basis":"billable_m3","mode":"unit","quantity":0.3042,"rate":25,"amount":7.61}]',22,0) returning id into m;
rejected:=false;
begin perform public.portal_invoice_snapshot(m,'TEST','2099-11-30','2099-12-30','Bonifico','',true); exception when others then if sqlerrm like 'Spazio occupato da ricalcolare:%' then rejected:=true;else raise;end if;end;
assert rejected,'Vecchio snapshot non bloccato';
update public.portal_months set invoice_lines='[{"basis":"billable_m3","mode":"unit","quantity":0.30,"rate":25,"amount":7.61}]' where id=m;
rejected:=false;
begin perform public.portal_invoice_snapshot(m,'TEST','2099-11-30','2099-12-30','Bonifico','',true); exception when others then if sqlerrm like 'Spazio occupato da ricalcolare:%' then rejected:=true;else raise;end if;end;
assert rejected,'Importo incoerente non bloccato';
update public.portal_months set invoice_lines='[{"basis":"billable_m3","mode":"unit","quantity":0.30,"rate":25,"amount":7.50}]' where id=m;
s:=public.portal_invoice_snapshot(m,'TEST','2099-11-30','2099-12-30','Bonifico','',true);
assert (s->>'net_amount')::numeric=7.50 and (s->>'vat_amount')::numeric=1.65 and (s->>'total_amount')::numeric=9.15,'Totali incoerenti';
end $test$;
select 'Tre verifiche snapshot superate; fixture sintetiche eliminate con rollback' as esito;
rollback;
