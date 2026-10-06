alter table public.portal_clients add column contact_info text not null default '', add column operational_notes text not null default '', add column billing_rules jsonb;
alter table public.portal_clients add constraint billing_rules_array check (billing_rules is null or jsonb_typeof(billing_rules)='array');
alter table public.portal_months add column stock_pieces bigint check(stock_pieces>=0), add column shipped_pieces bigint check(shipped_pieces>=0), add column received_pieces bigint check(received_pieces>=0), add column created_shipments bigint check(created_shipments>=0), add column invoice_lines jsonb;
alter table public.portal_months add constraint invoice_lines_array check(invoice_lines is null or jsonb_typeof(invoice_lines)='array');
create table public.portal_client_photos(id uuid primary key default gen_random_uuid(),client_id uuid not null references public.portal_clients(id),object_path text not null unique,caption text not null default '',created_at timestamptz not null default now());
create index portal_client_photos_client on public.portal_client_photos(client_id);
alter table public.portal_client_photos enable row level security;
revoke all on public.portal_client_photos from anon;
grant select,insert,update,delete on public.portal_client_photos to authenticated;
create policy photos_read on public.portal_client_photos for select to authenticated using(exists(select 1 from public.portal_admins where user_id=(select auth.uid())) or exists(select 1 from public.portal_members where user_id=(select auth.uid()) and client_id=portal_client_photos.client_id));
create policy photos_admin on public.portal_client_photos for all to authenticated using(exists(select 1 from public.portal_admins where user_id=(select auth.uid()))) with check(exists(select 1 from public.portal_admins where user_id=(select auth.uid())) and split_part(object_path,'/',1)=client_id::text);
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('client-procedures','client-procedures',false,10485760,array['image/jpeg','image/png','image/webp']) on conflict(id) do nothing;
create policy procedure_images_read on storage.objects for select to authenticated using(bucket_id='client-procedures' and (exists(select 1 from public.portal_admins where user_id=(select auth.uid())) or exists(select 1 from public.portal_members where user_id=(select auth.uid()) and client_id::text=(storage.foldername(name))[1])));
create policy procedure_images_insert on storage.objects for insert to authenticated with check(bucket_id='client-procedures' and exists(select 1 from public.portal_admins where user_id=(select auth.uid())) and exists(select 1 from public.portal_clients where id::text=(storage.foldername(objects.name))[1]));
create policy procedure_images_delete on storage.objects for delete to authenticated using(bucket_id='client-procedures' and exists(select 1 from public.portal_admins where user_id=(select auth.uid())));
create or replace function public.portal_storage_invalidate_month() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if TG_OP in ('UPDATE','DELETE') then update public.portal_months set released=false,billable_m3=null,invoice_lines=(select jsonb_agg(case when line->>'basis'='billable_m3' then line || jsonb_build_object('quantity',null,'amount',case when line->>'mode'='unit' then null else line->'amount' end) else line end order by ord) from jsonb_array_elements(invoice_lines) with ordinality as entries(line,ord)) where client_id=OLD.client_id and month=date_trunc('month',OLD.observed_on)::date and storage_basis='daily_average'; end if;
 if TG_OP in ('INSERT','UPDATE') then update public.portal_months set released=false,billable_m3=null,invoice_lines=(select jsonb_agg(case when line->>'basis'='billable_m3' then line || jsonb_build_object('quantity',null,'amount',case when line->>'mode'='unit' then null else line->'amount' end) else line end order by ord) from jsonb_array_elements(invoice_lines) with ordinality as entries(line,ord)) where client_id=NEW.client_id and month=date_trunc('month',NEW.observed_on)::date and storage_basis='daily_average'; end if;
 return null;
end $$;
