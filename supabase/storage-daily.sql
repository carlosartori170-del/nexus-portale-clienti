create table public.portal_storage_days(
id uuid primary key default gen_random_uuid(),
client_id uuid not null references public.portal_clients(id),
observed_on date not null,
volume_m3 numeric(18,8) not null check(volume_m3>=0),
total_units bigint not null check(total_units>=0),
sku_count integer not null check(sku_count>=0),
zero_volume_skus integer not null default 0 check(zero_volume_skus>=0),
date_source text not null default 'manual' check(date_source in('manual','filename_epoch')),
source_name text not null,
items jsonb not null default '[]'::jsonb check(jsonb_typeof(items)='array'),
created_at timestamptz not null default now(),
unique(client_id,observed_on));
create index on public.portal_storage_days(client_id,observed_on);
alter table public.portal_storage_days enable row level security;
revoke all on public.portal_storage_days from anon,authenticated;
grant select,insert,update,delete on public.portal_storage_days to authenticated;
create policy storage_days_read on public.portal_storage_days for select to authenticated using(exists(select 1 from public.portal_admins) or client_id in(select client_id from public.portal_members where user_id=(select auth.uid())));
create policy storage_days_admin on public.portal_storage_days for all to authenticated using(exists(select 1 from public.portal_admins)) with check(exists(select 1 from public.portal_admins));
alter table public.portal_months add column storage_basis text not null default 'manual' check(storage_basis in('manual','daily_average'));
alter table public.portal_months alter column billable_m3 type numeric(18,8);
create function public.portal_storage_invalidate_month() returns trigger language plpgsql security invoker set search_path='' as $$
begin
if TG_OP in('UPDATE','DELETE') then
update public.portal_months set released=false,billable_m3=null where client_id=OLD.client_id and month=date_trunc('month',OLD.observed_on)::date and storage_basis='daily_average';
end if;
if TG_OP in('INSERT','UPDATE') then
update public.portal_months set released=false,billable_m3=null where client_id=NEW.client_id and month=date_trunc('month',NEW.observed_on)::date and storage_basis='daily_average';
end if;
return null;
end $$;
revoke all on function public.portal_storage_invalidate_month() from public,anon,authenticated;
create trigger portal_storage_month_changed after insert or update or delete on public.portal_storage_days for each row execute function public.portal_storage_invalidate_month();