-- Additive stock ledger. Existing rows have no stock and no source link.
alter table public.portal_daily_dispatches
 add column stock_pieces bigint not null default 0,
 add column stock_source_id uuid references public.portal_daily_dispatches(id) on delete restrict,
 add constraint daily_stock_pieces_check check(stock_pieces between 0 and piece_count),
 add constraint daily_stock_source_check check(stock_source_id is null or (stock_source_id<>id and stock_pieces=0 and piece_count>0 and shipment_count>0));
create index daily_stock_source_idx on public.portal_daily_dispatches(stock_source_id) where stock_source_id is not null;

-- Stock is the original reserve; remaining stock is reserve minus linked pieces.
-- Locking the origin serializes inserts/edits/deletes against the same reserve.
create function public.portal_daily_stock_guard() returns trigger
language plpgsql security invoker set search_path='' as $$
declare source public.portal_daily_dispatches%rowtype; used numeric;
begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then
  raise exception 'Accesso riservato a Nexus' using errcode='42501';
 end if;
 if TG_OP='DELETE' then
  if old.stock_source_id is not null then
   perform 1 from public.portal_daily_dispatches where id=old.stock_source_id for update;
  elsif exists(select 1 from public.portal_daily_dispatches where stock_source_id=old.id) then
   raise exception 'La registrazione ha spedizioni da giacenza collegate: elimina prima quelle righe';
  end if;
  return old;
 end if;
 if TG_OP='UPDATE' then
  if new.id<>old.id or new.stock_source_id is distinct from old.stock_source_id then
   raise exception 'Il collegamento alla giacenza originale non può essere modificato';
  end if;
 end if;
 if new.stock_source_id is not null then
  select * into source from public.portal_daily_dispatches where id=new.stock_source_id for update;
  if not found or source.stock_source_id is not null then raise exception 'Registrazione di giacenza originale non disponibile';end if;
  if new.client_id<>source.client_id or new.received_on<>source.received_on or trim(new.supplier)<>source.supplier then
   raise exception 'Cliente, data ricevimento e fornitore devono corrispondere alla giacenza originale';
  end if;
  if date_trunc('month',new.shipped_on)<=date_trunc('month',source.shipped_on) or new.shipped_on<source.received_on then
   raise exception 'Usa una data di spedizione in un mese successivo alla registrazione originale';
  end if;
  if not public.portal_client_active_in_month(new.client_id,date_trunc('month',new.shipped_on)::date) then
   raise exception 'Cliente non attivo nel mese della spedizione';
  end if;
  select coalesce(sum(piece_count),0) into used from public.portal_daily_dispatches where stock_source_id=source.id and id<>new.id;
  if used+new.piece_count>source.stock_pieces then raise exception 'Pezzi richiesti superiori alla giacenza disponibile';end if;
 else
  select coalesce(sum(piece_count),0) into used from public.portal_daily_dispatches where stock_source_id=new.id;
  if used>new.stock_pieces then raise exception 'La giacenza non può essere inferiore ai pezzi già spediti con righe collegate';end if;
  if TG_OP='UPDATE' and used>0 and
     (new.client_id<>old.client_id or new.received_on<>old.received_on or new.shipped_on<>old.shipped_on or trim(new.supplier)<>old.supplier) then
   raise exception 'Ricevimento, fornitore, cliente e data originale sono collegati a spedizioni da giacenza';
  end if;
 end if;
 return new;
end $$;
revoke all on function public.portal_daily_stock_guard() from public,anon,authenticated;
create trigger daily_dispatch_00_stock_guard before insert or update or delete on public.portal_daily_dispatches
for each row execute function public.portal_daily_stock_guard();

create function public.portal_dispatch_from_stock(
 p_id uuid,p_source uuid,p_date date,p_pieces bigint,p_shipments integer,p_notes text,
 p_expected jsonb,p_expected_available bigint
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare source public.portal_daily_dispatches%rowtype; target public.portal_daily_dispatches%rowtype; available bigint;
begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501';end if;
 if p_id is null or p_source is null or p_date is null or p_pieces is null or p_pieces<1 or p_shipments is null or p_shipments<1 then
  raise exception 'Inserisci origine, data, pezzi e spedizioni con quantità intere positive';
 end if;
 select * into source from public.portal_daily_dispatches where id=p_source for update;
 if not found or source.stock_source_id is not null then raise exception 'Giacenza originale non disponibile: riapri la finestra';end if;
 select * into target from public.portal_daily_dispatches where id=p_id;
 if found then
  if target.stock_source_id=p_source and target.shipped_on=p_date and target.piece_count=p_pieces
     and target.shipment_count=p_shipments and target.notes=coalesce(p_notes,'') then return to_jsonb(target);end if;
  raise exception 'Registrazione già presente con dati diversi: aggiorna il registro';
 end if;
 if to_jsonb(source) is distinct from p_expected then raise exception 'Giacenza modificata: riapri la finestra';end if;
 select source.stock_pieces-coalesce(sum(piece_count),0) into available from public.portal_daily_dispatches where stock_source_id=p_source;
 if available is distinct from p_expected_available then raise exception 'Giacenza modificata da un’altra spedizione: riapri la finestra';end if;
 insert into public.portal_daily_dispatches(id,client_id,shipped_on,received_on,supplier,piece_count,shipment_count,notes,stock_source_id)
 values(p_id,source.client_id,p_date,source.received_on,source.supplier,p_pieces,p_shipments,coalesce(p_notes,''),p_source) returning * into target;
 return to_jsonb(target);
end $$;
revoke all on function public.portal_dispatch_from_stock(uuid,uuid,date,bigint,integer,text,jsonb,bigint) from public,anon;
grant execute on function public.portal_dispatch_from_stock(uuid,uuid,date,bigint,integer,text,jsonb,bigint) to authenticated;

-- Forms edit REMAINING pieces. Stored reserve also includes already linked pieces.
create function public.portal_save_daily_dispatch(p_id uuid,p_values jsonb,p_expected jsonb,p_expected_used bigint)
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
 if (p_values->>'stock_pieces')::bigint<0 then raise exception 'La giacenza non può essere negativa';end if;
 if present and p_expected is null then
  if target.stock_source_id is null and target.client_id=desired.client_id and target.shipped_on=desired.shipped_on
     and target.received_on=desired.received_on and target.supplier=desired.supplier and target.piece_count=desired.piece_count
     and target.shipment_count=desired.shipment_count and target.stock_pieces=desired.stock_pieces and target.notes=desired.notes then return to_jsonb(target);end if;
  raise exception 'Registrazione già presente: aggiorna il registro';
 elsif present then
  update public.portal_daily_dispatches set client_id=desired.client_id,shipped_on=desired.shipped_on,received_on=desired.received_on,
    supplier=desired.supplier,piece_count=desired.piece_count,shipment_count=desired.shipment_count,stock_pieces=desired.stock_pieces,notes=desired.notes
  where id=p_id returning * into target;
 else
  insert into public.portal_daily_dispatches(id,client_id,shipped_on,received_on,supplier,piece_count,shipment_count,stock_pieces,notes)
  values(p_id,desired.client_id,desired.shipped_on,desired.received_on,desired.supplier,desired.piece_count,desired.shipment_count,desired.stock_pieces,desired.notes)
  returning * into target;
 end if;
 return to_jsonb(target);
end $$;
revoke all on function public.portal_save_daily_dispatch(uuid,jsonb,jsonb,bigint) from public,anon;
grant execute on function public.portal_save_daily_dispatch(uuid,jsonb,jsonb,bigint) to authenticated;
