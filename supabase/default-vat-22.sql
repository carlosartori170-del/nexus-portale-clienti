alter table public.portal_clients alter column vat_rate set default 22;
update public.portal_clients set vat_rate=22;
alter table public.portal_clients alter column vat_rate set not null;
alter table public.portal_months alter column vat_rate set default 22;
update public.portal_months set vat_rate=22 where not released and not workflow_managed;
