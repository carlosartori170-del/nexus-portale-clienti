-- Da applicare dopo approvazione. Nessuna riga esistente viene classificata come Nexus.
alter table public.portal_carrier_charges add column nexus_owned boolean not null default false;
alter table public.portal_carrier_charges add constraint portal_charge_nexus_unlinked check (not nexus_owned or shipment_id is null);
comment on column public.portal_carrier_charges.nexus_owned is 'Costo di una spedizione interna Nexus: conservato, senza addebito ai clienti.';
create or replace function public.portal_assign_carrier_charge(
 p_charge uuid,p_nexus_owned boolean,p_shipment uuid,p_expected jsonb,
 p_clear_customer_charge boolean default false,p_expected_customer_charge numeric default null
) returns jsonb language plpgsql security invoker set search_path=''
as $assignment$
declare c public.portal_carrier_charges%rowtype; old_shipment public.portal_shipments%rowtype; target public.portal_shipments%rowtype;
begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501';end if;
 if p_nexus_owned is null then raise exception 'Destinazione del costo mancante';end if;
 select * into c from public.portal_carrier_charges where id=p_charge for update;
 if not found then raise exception 'Addebito non trovato';end if;
 if p_expected is null or to_jsonb(c)<>p_expected then raise exception 'Addebito modificato: riapri l’anteprima';end if;
 if p_nexus_owned and p_shipment is not null then raise exception 'Una spedizione Nexus non può essere abbinata a un cliente';end if;
 perform 1 from public.portal_shipments where id=c.shipment_id or id=p_shipment order by id for update;
 if c.shipment_id is not null then select * into old_shipment from public.portal_shipments where id=c.shipment_id;end if;
 if p_nexus_owned and c.shipment_id is not null then
  if old_shipment.customer_charge is distinct from p_expected_customer_charge then raise exception 'Importo al cliente modificato: riapri l’anteprima';end if;
  if old_shipment.customer_charge is not null then
   if not coalesce(p_clear_customer_charge,false) then raise exception 'Conferma la rimozione dell’importo al cliente prima di classificare la spedizione come Nexus';end if;
   if exists(select 1 from public.portal_carrier_charges where shipment_id=c.shipment_id and id<>c.id) then raise exception 'La spedizione ha altri costi collegati: verifica prima l’importo al cliente e gli abbinamenti';end if;
   update public.portal_shipments set customer_charge=null where id=c.shipment_id;
  end if;
 end if;
 if p_shipment is not null then
  select * into target from public.portal_shipments where id=p_shipment;
  if not found then raise exception 'Spedizione non trovata';end if;
  if exists(select 1 from public.portal_clients where id=target.client_id and (billing_quantity_source='manual' or billing_daily_shipments)) then raise exception 'Cliente con gestione manuale / contratto proprio: verifica la destinazione del costo';end if;
  if c.invoice_number='CSV SPEDIAMO PRO' and exists(select 1 from public.portal_carrier_charges where shipment_id=p_shipment and id<>p_charge) then raise exception 'Su questa spedizione è già presente un costo: verifica per evitare duplicati';end if;
 end if;
 update public.portal_carrier_charges
 set nexus_owned=p_nexus_owned,shipment_id=case when p_nexus_owned then null else p_shipment end,
 shipped_on=case when not p_nexus_owned and p_shipment is not null and invoice_number='CSV SPEDIAMO PRO' then target.shipped_on else shipped_on end,
 month=case when not p_nexus_owned and p_shipment is not null and invoice_number='CSV SPEDIAMO PRO' then date_trunc('month',target.shipped_on)::date else month end
 where id=p_charge returning * into c;
 return to_jsonb(c);
end $assignment$;
revoke all on function public.portal_assign_carrier_charge(uuid,boolean,uuid,jsonb,boolean,numeric) from public,anon;
grant execute on function public.portal_assign_carrier_charge(uuid,boolean,uuid,jsonb,boolean,numeric) to authenticated;
