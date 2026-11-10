-- Costi manuali in attesa della fattura. Nessuna conversione dei costi esistenti.
alter table public.portal_carrier_charges add column manual_provisional boolean not null default false;
alter table public.portal_carrier_charges add constraint portal_manual_carrier_destination
 check (not manual_provisional or (shipment_id is not null and not nexus_owned and direct_client_id is null));
create unique index portal_one_manual_cost_per_shipment on public.portal_carrier_charges(shipment_id) where manual_provisional;

-- Protegge anche import, abbinamenti e richieste concorrenti da due costi
-- (manuale + fattura) sulla stessa spedizione. I supplementi reali restano ammessi.
create function public.portal_guard_manual_carrier_cost() returns trigger
language plpgsql security invoker set search_path='' as $$
begin
 if new.shipment_id is not null then
  perform 1 from public.portal_shipments where id=new.shipment_id for update;
  if exists(select 1 from public.portal_carrier_charges c where c.shipment_id=new.shipment_id and c.id<>new.id and (new.manual_provisional or c.manual_provisional)) then
   raise exception 'Spedizione con costo già presente: usa Sostituisci con fattura sulla riga manuale, senza aggiungere un secondo addebito';
  end if;
 end if;
 return new;
end $$;
revoke all on function public.portal_guard_manual_carrier_cost() from public,anon;
create trigger guard_manual_carrier_cost before insert or update on public.portal_carrier_charges
for each row execute function public.portal_guard_manual_carrier_cost();

create function public.portal_save_manual_carrier_cost(p_shipment uuid,p_amount numeric,p_expected_shipment jsonb,p_charge uuid default null,p_expected_charge jsonb default null)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare s public.portal_shipments%rowtype; c public.portal_carrier_charges%rowtype;
begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501';end if;
 if p_amount is null or p_amount::text in ('NaN','Infinity','-Infinity') or p_amount<0 or p_amount<>round(p_amount,2) then raise exception 'Inserisci un importo IVA esclusa non negativo, con massimo due decimali';end if;
 select * into s from public.portal_shipments where id=p_shipment for update;
 if not found then raise exception 'Spedizione non trovata';end if;
 if p_expected_shipment is null or to_jsonb(s)<>p_expected_shipment then raise exception 'Spedizione o importo modificato: riapri il modulo';end if;
 if exists(select 1 from public.portal_clients where id=s.client_id and (billing_quantity_source='manual' or billing_daily_shipments)) then raise exception 'Cliente con gestione manuale / contratto proprio: verifica prima il costo corriere';end if;
 if p_charge is not null then
  select * into c from public.portal_carrier_charges where id=p_charge for update;
  if not found or not c.manual_provisional or c.shipment_id is distinct from s.id then raise exception 'Costo manuale non trovato';end if;
  if p_expected_charge is null or to_jsonb(c)<>p_expected_charge then raise exception 'Costo modificato: riapri il modulo';end if;
 end if;
 if exists(select 1 from public.portal_carrier_charges where shipment_id=s.id and (p_charge is null or id<>p_charge)) then raise exception 'Spedizione con costo già presente: aggiorna la pagina';end if;
 if p_charge is null then
  insert into public.portal_carrier_charges(invoice_number,month,carrier_code,reference,recipient,postcode,shipped_on,transport,fuel,extras,shipment_id,manual_provisional)
  values('IMPORTO MANUALE',date_trunc('month',s.shipped_on)::date,'MANUALE-'||s.id::text,coalesce(nullif(s.tracking,''),nullif(s.reference,''),s.code),s.recipient,s.postcode,s.shipped_on,p_amount,0,0,s.id,true) returning * into c;
 else
  update public.portal_carrier_charges set transport=p_amount,fuel=0,extras=0 where id=p_charge returning * into c;
 end if;
 update public.portal_shipments set customer_charge=p_amount where id=s.id;
 return to_jsonb(c);
end $$;
revoke all on function public.portal_save_manual_carrier_cost(uuid,numeric,jsonb,uuid,jsonb) from public,anon;
grant execute on function public.portal_save_manual_carrier_cost(uuid,numeric,jsonb,uuid,jsonb) to authenticated;

-- Sostituisce il costo manuale con UNA riga già importata e aggiorna il
-- riaddebito senza ricarico. Le convalide vengono invalidate dai trigger esistenti.
create function public.portal_replace_manual_carrier_cost(p_manual uuid,p_actual uuid,p_expected_manual jsonb,p_expected_actual jsonb,p_expected_shipment jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare c public.portal_carrier_charges%rowtype; a public.portal_carrier_charges%rowtype; s public.portal_shipments%rowtype; sid uuid; result jsonb; total numeric;
begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501';end if;
 select shipment_id into sid from public.portal_carrier_charges where id=p_manual and manual_provisional;
 if sid is null or p_manual=p_actual then raise exception 'Costo manuale non trovato';end if;
 select * into s from public.portal_shipments where id=sid for update;
 perform 1 from public.portal_carrier_charges where id in (p_manual,p_actual) order by id for update;
 select * into c from public.portal_carrier_charges where id=p_manual;
 select * into a from public.portal_carrier_charges where id=p_actual;
 if p_expected_manual is null or p_expected_actual is null or p_expected_shipment is null or to_jsonb(c) is distinct from p_expected_manual or to_jsonb(a) is distinct from p_expected_actual or to_jsonb(s) is distinct from p_expected_shipment then raise exception 'Costi o spedizione modificati: riapri il modulo';end if;
 if not c.manual_provisional or c.shipment_id is distinct from sid or a.manual_provisional or a.nexus_owned or a.direct_client_id is not null or a.shipment_id is not null then raise exception 'Scegli una riga di fattura ancora da abbinare';end if;
 if s.customer_charge is distinct from c.transport+c.fuel+c.extras then raise exception 'Importo cliente diverso dal costo manuale: verifica prima di sostituire';end if;
 if exists(select 1 from public.portal_carrier_charges where shipment_id=s.id and id<>c.id) then raise exception 'Altri costi presenti: verifica prima di sostituire';end if;
 total:=a.transport+a.fuel+a.extras;
 if total::text in ('NaN','Infinity','-Infinity') or total<0 then raise exception 'Importo della fattura non valido';end if;
 delete from public.portal_carrier_charges where id=c.id;
 result:=public.portal_assign_carrier_destination(a.id,false,s.id,to_jsonb(a),false,s.customer_charge,null);
 update public.portal_shipments set customer_charge=total where id=s.id;
 return result;
end $$;
revoke all on function public.portal_replace_manual_carrier_cost(uuid,uuid,jsonb,jsonb,jsonb) from public,anon;
grant execute on function public.portal_replace_manual_carrier_cost(uuid,uuid,jsonb,jsonb,jsonb) to authenticated;
