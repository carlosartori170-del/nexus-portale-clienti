-- One receipt delivery note, shared by all linked stock shipments.
alter table public.portal_daily_dispatches
 add column delivery_note text not null default '',
 add constraint daily_delivery_note_length check(length(delivery_note)<=100),
 add constraint daily_delivery_note_origin check(stock_source_id is null or delivery_note='');

create or replace function public.portal_save_daily_dispatch(p_id uuid,p_values jsonb,p_expected jsonb,p_expected_used bigint)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare target public.portal_daily_dispatches%rowtype; desired public.portal_daily_dispatches%rowtype; used bigint:=0; present boolean;
begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501';end if;
 if p_id is null or p_values is null then raise exception 'Registrazione non valida';end if;
 select * into target from public.portal_daily_dispatches where id=p_id for update;present:=found;
 if p_expected is not null and (not present or to_jsonb(target) is distinct from p_expected) then
  raise exception 'Registrazione modificata: riapri la finestra';
 end if;
 if present and p_expected is not null then
  select coalesce(sum(piece_count),0) into used from public.portal_daily_dispatches where stock_source_id=p_id;
  if used is distinct from p_expected_used then raise exception 'Giacenza modificata da una spedizione: riapri la finestra';end if;
 end if;
 desired.client_id:=(p_values->>'client_id')::uuid;
 desired.shipped_on:=(p_values->>'shipped_on')::date;
 desired.received_on:=(p_values->>'received_on')::date;
 desired.supplier:=trim(p_values->>'supplier');
 desired.piece_count:=(p_values->>'piece_count')::bigint;
 desired.shipment_count:=(p_values->>'shipment_count')::integer;
 desired.stock_pieces:=(p_values->>'stock_pieces')::bigint+used;
 desired.notes:=coalesce(p_values->>'notes','');
 desired.delivery_note:=case when p_values ? 'delivery_note' then trim(coalesce(p_values->>'delivery_note','')) else coalesce(target.delivery_note,'') end;
 if length(desired.delivery_note)>100 then raise exception 'Il numero bolla può contenere al massimo 100 caratteri';end if;
 if (p_values->>'stock_pieces')::bigint<0 then raise exception 'La giacenza non può essere negativa';end if;
 if present and p_expected is null then
  if target.stock_source_id is null and target.client_id=desired.client_id and target.shipped_on=desired.shipped_on
     and target.received_on=desired.received_on and target.supplier=desired.supplier and target.piece_count=desired.piece_count
     and target.shipment_count=desired.shipment_count and target.stock_pieces=desired.stock_pieces and target.notes=desired.notes and target.delivery_note=desired.delivery_note then return to_jsonb(target);end if;
  raise exception 'Registrazione già presente: aggiorna il registro';
 elsif present then
  update public.portal_daily_dispatches set client_id=desired.client_id,shipped_on=desired.shipped_on,received_on=desired.received_on,
    supplier=desired.supplier,piece_count=desired.piece_count,shipment_count=desired.shipment_count,stock_pieces=desired.stock_pieces,notes=desired.notes,delivery_note=desired.delivery_note
  where id=p_id returning * into target;
 else
  insert into public.portal_daily_dispatches(id,client_id,shipped_on,received_on,supplier,piece_count,shipment_count,stock_pieces,notes,delivery_note)
  values(p_id,desired.client_id,desired.shipped_on,desired.received_on,desired.supplier,desired.piece_count,desired.shipment_count,desired.stock_pieces,desired.notes,desired.delivery_note)
  returning * into target;
 end if;
 return to_jsonb(target);
end $$;
revoke all on function public.portal_save_daily_dispatch(uuid,jsonb,jsonb,bigint) from public,anon;
grant execute on function public.portal_save_daily_dispatch(uuid,jsonb,jsonb,bigint) to authenticated;
