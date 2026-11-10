-- Uno sconto commerciale per cliente e mese; nessuna modifica ai dati esistenti.
create table public.portal_invoice_discounts(
 client_id uuid not null references public.portal_clients(id),
 month date not null check(extract(day from month)=1),
 amount numeric(14,2) not null default 0 check(amount>=0 and amount<>'NaN'::numeric),
 description text not null default '' check(length(description)<=500),
 updated_at timestamptz not null default now(),
 updated_by uuid references auth.users(id),
 primary key(client_id,month)
);
alter table public.portal_invoice_discounts enable row level security;
revoke all on public.portal_invoice_discounts from public,anon;
grant select,insert,update,delete on public.portal_invoice_discounts to authenticated;
create policy invoice_discounts_admin on public.portal_invoice_discounts for all to authenticated
 using(exists(select 1 from public.portal_admins where user_id=(select auth.uid())))
 with check(exists(select 1 from public.portal_admins where user_id=(select auth.uid())));

create function public.portal_invoice_discount_touch() returns trigger
language plpgsql security invoker set search_path='' as $$
begin new.updated_at:=now();new.updated_by:=auth.uid();return new;end $$;
revoke all on function public.portal_invoice_discount_touch() from public,anon;
create trigger invoice_discount_touch before insert or update on public.portal_invoice_discounts for each row execute function public.portal_invoice_discount_touch();

create function public.portal_invoice_discount_invalidate() returns trigger
language plpgsql security invoker set search_path='' as $$
begin
 if tg_op<>'INSERT' then update public.portal_months set released=false where client_id=old.client_id and month=old.month and workflow_managed;end if;
 if tg_op<>'DELETE' then update public.portal_months set released=false where client_id=new.client_id and month=new.month and workflow_managed;end if;
 return null;
end $$;
revoke all on function public.portal_invoice_discount_invalidate() from public,anon;
create trigger invoice_discount_invalidate after insert or update or delete on public.portal_invoice_discounts for each row execute function public.portal_invoice_discount_invalidate();

create function public.portal_set_invoice_discount(p_client uuid,p_month date,p_amount numeric,p_description text,p_expected_lines jsonb,p_expected_discount jsonb default null)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare m public.portal_months%rowtype; d public.portal_invoice_discounts%rowtype; current_discount jsonb; result jsonb;
begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501';end if;
 if p_month is null or p_month<>date_trunc('month',p_month)::date then raise exception 'Mese non valido';end if;
 if p_amount is null or p_amount::text in ('NaN','Infinity','-Infinity') or p_amount<0 or p_amount<>round(p_amount,2) then raise exception 'Inserisci uno sconto IVA esclusa non negativo con massimo due decimali';end if;
 if length(coalesce(p_description,''))>500 then raise exception 'Descrizione dello sconto troppo lunga';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_client::text||p_month::text,0));
 if not public.portal_client_active_in_month(p_client,p_month) then raise exception 'Cliente non attivo nel mese selezionato';end if;
 select * into m from public.portal_months where client_id=p_client and month=p_month for update;
 if not found or not m.workflow_managed or m.invoice_lines is null then raise exception 'Prepara prima la prefattura dalle sezioni convalidate';end if;
 if p_expected_lines is null or m.invoice_lines<>p_expected_lines then raise exception 'Prefattura modificata: aggiorna la pagina e riapri lo sconto';end if;
 if exists(select 1 from public.portal_clients c where c.id=p_client and (c.minimum_logistics is distinct from m.minimum_logistics or c.vat_rate is distinct from m.vat_rate)) then raise exception 'Minimo o IVA modificati: aggiorna prima la prefattura e ricontrolla gli importi';end if;
 select * into d from public.portal_invoice_discounts where client_id=p_client and month=p_month for update;
 if found then current_discount:=to_jsonb(d);end if;
 if current_discount is distinct from p_expected_discount then raise exception 'Sconto modificato: aggiorna la pagina e riapri il modulo';end if;
 insert into public.portal_invoice_discounts(client_id,month,amount,description)
 values(p_client,p_month,p_amount,trim(coalesce(p_description,'')))
 on conflict(client_id,month) do update set amount=excluded.amount,description=excluded.description;
 -- Il ricalcolo verifica convalide correnti, minimo, sconto e IVA. Qualunque
 -- errore annulla anche il salvataggio dello sconto e la riapertura del mese.
 result:=public.portal_build_preinvoice(p_client,p_month,false,false);
 return result;
end $$;
revoke all on function public.portal_set_invoice_discount(uuid,date,numeric,text,jsonb,jsonb) from public,anon;
grant execute on function public.portal_set_invoice_discount(uuid,date,numeric,text,jsonb,jsonb) to authenticated;
