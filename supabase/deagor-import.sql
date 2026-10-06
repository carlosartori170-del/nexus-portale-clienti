alter table public.portal_shipments add column shipped_pieces bigint check(shipped_pieces>=0), add column label_created_on date, add column tracking text, add column source_name text;
create table public.portal_inbounds(id uuid primary key default gen_random_uuid(),client_id uuid not null references public.portal_clients(id),code text not null check(length(trim(code))>0),received_on date not null,total_pieces bigint not null check(total_pieces>=0),source_name text,unique(client_id,code));
create index portal_inbounds_client_date on public.portal_inbounds(client_id,received_on);
alter table public.portal_inbounds enable row level security;
revoke all on public.portal_inbounds from anon;
grant select,insert,update,delete on public.portal_inbounds to authenticated;
create policy inbounds_read on public.portal_inbounds for select to authenticated using(exists(select 1 from public.portal_admins where user_id=(select auth.uid())) or exists(select 1 from public.portal_members where user_id=(select auth.uid()) and client_id=portal_inbounds.client_id));
create policy inbounds_admin on public.portal_inbounds for all to authenticated using(exists(select 1 from public.portal_admins where user_id=(select auth.uid()))) with check(exists(select 1 from public.portal_admins where user_id=(select auth.uid())));
create or replace function public.portal_import_deagor(p_orders jsonb default '[]',p_inbounds jsonb default '[]') returns jsonb language plpgsql security invoker set search_path='' as $$
declare r record; n integer; changed_orders integer:=0; changed_inbounds integer:=0;
begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501'; end if;
 if jsonb_typeof(p_orders)<>'array' or jsonb_typeof(p_inbounds)<>'array' or jsonb_array_length(p_orders)+jsonb_array_length(p_inbounds)>5000 then raise exception 'Importazione non valida o troppo grande'; end if;
 for r in select * from jsonb_to_recordset(p_orders) as x(client_id uuid,code text,order_number text,shipped_on date,recipient text,postcode text,city text,carrier text,shipped_pieces bigint,label_created_on date,tracking text,source_name text) loop
 if r.code is null or trim(r.code)='' or r.shipped_on is null or r.shipped_pieces is null or r.recipient is null or trim(r.recipient)='' then raise exception 'Ordine incompleto'; end if;
 if exists(select 1 from public.portal_shipments where code=r.code and client_id<>r.client_id) then raise exception 'Spedizione già assegnata a un altro cliente: %',r.code; end if;
 insert into public.portal_shipments(client_id,code,order_number,shipped_on,recipient,postcode,city,carrier,shipped_pieces,label_created_on,tracking,source_name) values(r.client_id,r.code,r.order_number,r.shipped_on,r.recipient,r.postcode,r.city,r.carrier,r.shipped_pieces,r.label_created_on,r.tracking,r.source_name)
 on conflict(code) do update set order_number=excluded.order_number,shipped_on=excluded.shipped_on,recipient=excluded.recipient,postcode=excluded.postcode,city=excluded.city,carrier=excluded.carrier,shipped_pieces=excluded.shipped_pieces,label_created_on=excluded.label_created_on,tracking=excluded.tracking,source_name=excluded.source_name
 where (portal_shipments.order_number,portal_shipments.shipped_on,portal_shipments.recipient,portal_shipments.postcode,portal_shipments.city,portal_shipments.carrier,portal_shipments.shipped_pieces,portal_shipments.label_created_on,portal_shipments.tracking) is distinct from (excluded.order_number,excluded.shipped_on,excluded.recipient,excluded.postcode,excluded.city,excluded.carrier,excluded.shipped_pieces,excluded.label_created_on,excluded.tracking);
 get diagnostics n=row_count; changed_orders:=changed_orders+n;
 end loop;
 for r in select * from jsonb_to_recordset(p_inbounds) as x(client_id uuid,code text,received_on date,total_pieces bigint,source_name text) loop
 insert into public.portal_inbounds(client_id,code,received_on,total_pieces,source_name) values(r.client_id,r.code,r.received_on,r.total_pieces,r.source_name)
 on conflict(client_id,code) do update set received_on=excluded.received_on,total_pieces=excluded.total_pieces,source_name=excluded.source_name where (portal_inbounds.received_on,portal_inbounds.total_pieces) is distinct from(excluded.received_on,excluded.total_pieces);
 get diagnostics n=row_count; changed_inbounds:=changed_inbounds+n;
 end loop;
 return jsonb_build_object('orders',changed_orders,'inbounds',changed_inbounds);
end $$;
revoke all on function public.portal_import_deagor(jsonb,jsonb) from public,anon;
grant execute on function public.portal_import_deagor(jsonb,jsonb) to authenticated;
create function public.portal_movement_invalidate_month() returns trigger language plpgsql security invoker set search_path='' as $$
declare rec jsonb; cid uuid; dates date[]; affected_month date; bases text[];
begin
 if TG_OP='UPDATE' then
  if TG_TABLE_NAME='portal_shipments' and (to_jsonb(OLD)->'client_id',to_jsonb(OLD)->'order_number',to_jsonb(OLD)->'shipped_on',to_jsonb(OLD)->'shipped_pieces',to_jsonb(OLD)->'label_created_on') is not distinct from (to_jsonb(NEW)->'client_id',to_jsonb(NEW)->'order_number',to_jsonb(NEW)->'shipped_on',to_jsonb(NEW)->'shipped_pieces',to_jsonb(NEW)->'label_created_on') then return null; end if;
  if TG_TABLE_NAME='portal_inbounds' and (to_jsonb(OLD)->'client_id',to_jsonb(OLD)->'received_on',to_jsonb(OLD)->'total_pieces') is not distinct from (to_jsonb(NEW)->'client_id',to_jsonb(NEW)->'received_on',to_jsonb(NEW)->'total_pieces') then return null; end if;
 end if;
 bases:=case when TG_TABLE_NAME='portal_shipments' then array['billable_shipments','shipped_pieces','extra_pieces','created_shipments'] else array['received_pieces'] end;
 for rec in select v from (values(case when TG_OP<>'INSERT' then to_jsonb(OLD) end),(case when TG_OP<>'DELETE' then to_jsonb(NEW) end)) as records(v) where v is not null loop
 cid:=(rec->>'client_id')::uuid;
 dates:=case when TG_TABLE_NAME='portal_shipments' then array[(rec->>'shipped_on')::date,(rec->>'label_created_on')::date] else array[(rec->>'received_on')::date] end;
 for affected_month in select distinct date_trunc('month',d)::date from unnest(dates) d where d is not null loop
 update public.portal_months set released=false,
 billable_shipments=case when TG_TABLE_NAME='portal_shipments' then null else billable_shipments end,
 shipped_pieces=case when TG_TABLE_NAME='portal_shipments' then null else shipped_pieces end,
 created_shipments=case when TG_TABLE_NAME='portal_shipments' then null else created_shipments end,
 received_pieces=case when TG_TABLE_NAME='portal_inbounds' then null else received_pieces end,
 invoice_lines=(select jsonb_agg(case when line->>'basis'=any(bases) then line||jsonb_build_object('quantity',case when line->>'mode'='fixed' then 1 else null end,'amount',case when line->>'mode'='unit' then null else line->'amount' end) else line end order by ord) from jsonb_array_elements(invoice_lines) with ordinality as entries(line,ord))
 where client_id=cid and month=affected_month;
 end loop;
 end loop;
 return null;
end $$;
revoke all on function public.portal_movement_invalidate_month() from public,anon,authenticated;
create trigger shipment_quantities_changed after insert or update of order_number,shipped_on,shipped_pieces,label_created_on or delete on public.portal_shipments for each row execute function public.portal_movement_invalidate_month();
create trigger inbound_quantities_changed after insert or update or delete on public.portal_inbounds for each row execute function public.portal_movement_invalidate_month();
create function public.portal_import_deagor_batch(p_orders jsonb default '[]',p_inbounds jsonb default '[]',p_snapshots jsonb default '[]',p_replace boolean default false) returns jsonb language plpgsql security invoker set search_path='' as $$
declare result jsonb; r record; n integer; changed_snapshots integer:=0;
begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501'; end if;
 if jsonb_typeof(p_snapshots)<>'array' or jsonb_array_length(p_snapshots)>100 then raise exception 'Numero inventari non valido'; end if;
 result:=public.portal_import_deagor(p_orders,p_inbounds);
 for r in select * from jsonb_to_recordset(p_snapshots) as x(client_id uuid,observed_on date,volume_m3 numeric,total_units bigint,sku_count integer,zero_volume_skus integer,date_source text,source_name text,items jsonb) loop
 insert into public.portal_storage_days(client_id,observed_on,volume_m3,total_units,sku_count,zero_volume_skus,date_source,source_name,items) values(r.client_id,r.observed_on,r.volume_m3,r.total_units,r.sku_count,r.zero_volume_skus,r.date_source,r.source_name,r.items)
 on conflict(client_id,observed_on) do update set volume_m3=excluded.volume_m3,total_units=excluded.total_units,sku_count=excluded.sku_count,zero_volume_skus=excluded.zero_volume_skus,date_source=excluded.date_source,source_name=excluded.source_name,items=excluded.items where p_replace and (portal_storage_days.volume_m3,portal_storage_days.total_units,portal_storage_days.sku_count,portal_storage_days.zero_volume_skus,portal_storage_days.items) is distinct from(excluded.volume_m3,excluded.total_units,excluded.sku_count,excluded.zero_volume_skus,excluded.items);
 get diagnostics n=row_count;changed_snapshots:=changed_snapshots+n;
 end loop;
 return result||jsonb_build_object('snapshots',changed_snapshots);
end $$;
revoke all on function public.portal_import_deagor_batch(jsonb,jsonb,jsonb,boolean) from public,anon;
grant execute on function public.portal_import_deagor_batch(jsonb,jsonb,jsonb,boolean) to authenticated;

create function public.portal_stock_invalidate_month() returns trigger language plpgsql security invoker set search_path='' as $$
declare rec jsonb; day date;
begin
 if TG_OP='UPDATE' and (OLD.client_id,OLD.observed_on,OLD.total_units) is not distinct from (NEW.client_id,NEW.observed_on,NEW.total_units) then return null; end if;
 for rec in select v from (values(case when TG_OP<>'INSERT' then to_jsonb(OLD) end),(case when TG_OP<>'DELETE' then to_jsonb(NEW) end)) as records(v) where v is not null loop
 day:=(rec->>'observed_on')::date;
 if day=(date_trunc('month',day)+interval '1 month - 1 day')::date then
 update public.portal_months set released=false,stock_pieces=null,invoice_lines=(select jsonb_agg(case when line->>'basis'='stock_pieces' then line||jsonb_build_object('quantity',case when line->>'mode'='fixed' then 1 else null end,'amount',case when line->>'mode'='unit' then null else line->'amount' end) else line end order by ord) from jsonb_array_elements(invoice_lines) with ordinality as entries(line,ord)) where client_id=(rec->>'client_id')::uuid and month=date_trunc('month',day)::date;
 end if;
 end loop;
 return null;
end $$;
revoke all on function public.portal_stock_invalidate_month() from public,anon,authenticated;
create trigger stock_quantities_changed after insert or update or delete on public.portal_storage_days for each row execute function public.portal_stock_invalidate_month();
