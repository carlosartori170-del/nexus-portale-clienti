-- Additive CRM: existing portal tables, users and policies are not changed.
create table public.crm_leads (
 id uuid primary key default gen_random_uuid(),
 slug text not null unique check(length(trim(slug)) between 1 and 200),
 azienda text not null check(length(trim(azienda)) between 1 and 500),
 settore text check(settore in ('Cosmetica e cura persona','Casa e lifestyle','Pet','Altro')),
 sito text,citta text,piattaforma text,segnali_crescita text,referente text,contatto_pubblico text,
 priorita text not null default 'Media' check(priorita in ('Alta','Media','Bassa')),fonte text,messaggio_linkedin text,
 stato text not null default 'da_contattare' check(stato in ('da_contattare','contattato','risposto','appuntamento','cliente','perso')),
 note text,assegnato_a text default 'Andrea D''Onofrio',prossimo_followup date,
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),updated_by uuid references auth.users(id)
);
create table public.crm_attivita (
 id uuid primary key default gen_random_uuid(),lead_id uuid not null references public.crm_leads(id) on delete cascade,
 tipo text not null check(tipo in ('cambio_stato','nota','messaggio_linkedin','telefonata','appuntamento')),
 descrizione text,created_at timestamptz not null default now(),created_by uuid references auth.users(id)
);
create index crm_leads_stato_idx on public.crm_leads(stato);
create index crm_leads_priorita_idx on public.crm_leads(priorita);
create index crm_leads_settore_idx on public.crm_leads(settore);
create index crm_attivita_lead_id_idx on public.crm_attivita(lead_id,created_at desc);
create index crm_leads_updated_by_idx on public.crm_leads(updated_by);
create index crm_attivita_created_by_idx on public.crm_attivita(created_by);
create function public.crm_is_admin() returns boolean language sql stable security invoker set search_path='' as $$
 select exists(select 1 from public.portal_admins where user_id=(select auth.uid()));
$$;
revoke all on function public.crm_is_admin() from public,anon;
grant execute on function public.crm_is_admin() to authenticated;
alter table public.crm_leads enable row level security;
alter table public.crm_attivita enable row level security;
revoke all on public.crm_leads,public.crm_attivita from public,anon;
grant select,insert,update,delete on public.crm_leads to authenticated;
grant select,insert on public.crm_attivita to authenticated;
create policy crm_leads_admin on public.crm_leads to authenticated
 using((select public.crm_is_admin())) with check((select public.crm_is_admin()));
create policy crm_attivita_admin_read on public.crm_attivita for select to authenticated using((select public.crm_is_admin()));
create policy crm_attivita_admin_insert on public.crm_attivita for insert to authenticated with check((select public.crm_is_admin()) and created_by=(select auth.uid()));
create function public.crm_stamp_lead() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if auth.uid() is null or not public.crm_is_admin() then raise exception 'CRM riservato agli amministratori Nexus' using errcode='42501';end if;
 if new.updated_by is distinct from auth.uid() then raise exception 'Utente di modifica non valido' using errcode='42501';end if;
 new.slug:=trim(new.slug);new.azienda:=trim(new.azienda);new.updated_at:=clock_timestamp();
 if TG_OP='UPDATE' then new.id:=old.id;new.created_at:=old.created_at;else new.created_at:=clock_timestamp();end if;
 return new;
end $$;
create trigger crm_leads_updated_at before insert or update on public.crm_leads for each row execute function public.crm_stamp_lead();
create function public.crm_record_status() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if old.stato is distinct from new.stato then
 insert into public.crm_attivita(lead_id,tipo,descrizione,created_by) values(new.id,'cambio_stato','da '||old.stato||' a '||new.stato,auth.uid());end if;
 return new;
end $$;
create trigger crm_leads_status_history after update of stato on public.crm_leads for each row execute function public.crm_record_status();
revoke all on function public.crm_stamp_lead(),public.crm_record_status() from public,anon;
-- Server-side upsert locks and protects worked status/notes even during concurrent imports.
create function public.crm_import_leads(p_rows jsonb) returns jsonb language plpgsql security invoker set search_path='' as $$
declare r jsonb; k text; line integer:=1; inserted boolean; n integer:=0;u integer:=0;skipped integer:=0; errors jsonb:='[]'; seen text[]:='{}'; reason text;
begin
 if not public.crm_is_admin() then raise exception 'CRM riservato agli amministratori Nexus' using errcode='42501';end if;
 if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows)>5000 then raise exception 'Import non valido: massimo 5000 righe';end if;
 for r in select value from jsonb_array_elements(p_rows) loop
 line:=line+1;
 begin
 if jsonb_typeof(r) is distinct from 'object' then raise exception 'Riga non valida';end if;
 foreach k in array array['slug','azienda','settore','sito','citta','piattaforma','segnali_crescita','referente','contatto_pubblico','priorita','fonte','messaggio_linkedin','stato','note','assegnato_a'] loop
 if jsonb_typeof(r->k) is distinct from 'string' then raise exception 'Campo mancante o non testuale: %',k;end if;end loop;
 if trim(r->>'slug')='' or trim(r->>'azienda')='' then raise exception 'Slug e azienda sono obbligatori';end if;
 if (r->>'settore') not in ('Cosmetica e cura persona','Casa e lifestyle','Pet','Altro') then raise exception 'Settore non valido';end if;
 if (r->>'priorita') not in ('Alta','Media','Bassa') then raise exception 'Priorità non valida';end if;
 if (r->>'stato') not in ('da_contattare','contattato','risposto','appuntamento','cliente','perso') then raise exception 'Stato non valido';end if;
 if trim(r->>'slug')=any(seen) then raise exception 'Slug duplicato nel file';end if;
 seen:=array_append(seen,trim(r->>'slug'));
 insert into public.crm_leads as target(slug,azienda,settore,sito,citta,piattaforma,segnali_crescita,referente,contatto_pubblico,priorita,fonte,messaggio_linkedin,stato,note,assegnato_a,updated_by)
 values(r->>'slug',r->>'azienda',r->>'settore',r->>'sito',r->>'citta',r->>'piattaforma',r->>'segnali_crescita',r->>'referente',r->>'contatto_pubblico',r->>'priorita',r->>'fonte',r->>'messaggio_linkedin',r->>'stato',r->>'note',coalesce(nullif(r->>'assegnato_a',''),'Andrea D''Onofrio'),auth.uid())
 on conflict(slug) do update set azienda=excluded.azienda,settore=excluded.settore,sito=excluded.sito,citta=excluded.citta,piattaforma=excluded.piattaforma,segnali_crescita=excluded.segnali_crescita,referente=excluded.referente,contatto_pubblico=excluded.contatto_pubblico,priorita=excluded.priorita,fonte=excluded.fonte,messaggio_linkedin=excluded.messaggio_linkedin,assegnato_a=excluded.assegnato_a,
 stato=case when target.stato<>'da_contattare' or length(trim(coalesce(target.note,'')))>0 then target.stato else excluded.stato end,
 note=case when target.stato<>'da_contattare' or length(trim(coalesce(target.note,'')))>0 then target.note else excluded.note end,updated_by=auth.uid()
 returning (xmax=0) into inserted;
 if inserted then n:=n+1;else u:=u+1;end if;
 exception when check_violation or not_null_violation or unique_violation or raise_exception then
 get stacked diagnostics reason=MESSAGE_TEXT;skipped:=skipped+1;errors:=errors||jsonb_build_array(jsonb_build_object('riga',line,'slug',r->>'slug','motivo',reason));
 end;
 end loop;
 return jsonb_build_object('inseriti',n,'aggiornati',u,'scartati',skipped,'errori',errors);
end $$;
revoke all on function public.crm_import_leads(jsonb) from public,anon;
grant execute on function public.crm_import_leads(jsonb) to authenticated;
create function public.crm_mark_linkedin(p_lead uuid,p_version timestamptz,p_message text) returns jsonb language plpgsql security invoker set search_path='' as $$
declare lead public.crm_leads%rowtype;
begin
 if not public.crm_is_admin() then raise exception 'CRM riservato agli amministratori Nexus' using errcode='42501';end if;
 update public.crm_leads set stato='contattato',updated_by=auth.uid() where id=p_lead and updated_at=p_version returning * into lead;
 if not found then raise exception 'Lead modificato: riapri la scheda prima di confermare';end if;
 insert into public.crm_attivita(lead_id,tipo,descrizione,created_by) values(p_lead,'messaggio_linkedin',p_message,auth.uid());
 return to_jsonb(lead);
end $$;
revoke all on function public.crm_mark_linkedin(uuid,timestamptz,text) from public,anon;
grant execute on function public.crm_mark_linkedin(uuid,timestamptz,text) to authenticated;
