-- Isolated tests: only generated crm-test-* leads are touched; rollback leaves no fixtures.
begin;
select set_config('request.jwt.claims',jsonb_build_object('sub',(select u.id from auth.users u join public.portal_admins a on a.user_id=u.id where lower(u.email)='carlo.sartori@nexus-srl.it' limit 1),'role','authenticated')::text,true);
set local role authenticated;
do $$
declare r jsonb;input jsonb;lead public.crm_leads%rowtype;original_created timestamptz;old_version timestamptz;bad boolean;fixture_slug text:='crm-test-'||gen_random_uuid()::text;
begin
 input:=jsonb_build_array(jsonb_build_object('slug',fixture_slug,'azienda','Test CRM isolato','settore','Pet','sito','','citta','Milano','piattaforma','Da verificare','segnali_crescita','Test','referente','Test','contatto_pubblico','','priorita','Alta','fonte','test','messaggio_linkedin',E'Ciao,\nMessaggio di prova\nAndrea','stato','da_contattare','note','','assegnato_a','Andrea D''Onofrio'));
 r:=public.crm_import_leads(input);assert (r->>'inseriti')::int=1 and (r->>'scartati')::int=0,r::text;
 select * into lead from public.crm_leads where crm_leads.slug=fixture_slug;original_created:=lead.created_at;
 assert lead.updated_by=auth.uid();
 update public.crm_leads set stato='risposto',updated_by=auth.uid() where id=lead.id;
 assert exists(select 1 from public.crm_attivita where lead_id=lead.id and tipo='cambio_stato' and descrizione='da da_contattare a risposto' and created_by=auth.uid()),'Missing status history';
 insert into public.crm_attivita(lead_id,tipo,descrizione,created_by) values(lead.id,'nota','Nota di prova isolata',auth.uid());
 update public.crm_leads set note='Nota commerciale da conservare',prossimo_followup='2099-12-01',updated_by=auth.uid() where id=lead.id;
 r:=public.crm_import_leads(input);assert (r->>'aggiornati')::int=1,r::text;
 select * into lead from public.crm_leads where crm_leads.slug=fixture_slug;
 assert lead.stato='risposto' and lead.note='Nota commerciale da conservare' and lead.prossimo_followup='2099-12-01' and lead.created_at=original_created,'Reimport lost work';
 assert (select count(*) from public.crm_attivita where lead_id=lead.id)=2,'Reimport added false state history';
 old_version:=lead.updated_at;
 r:=public.crm_mark_linkedin(lead.id,lead.updated_at,lead.messaggio_linkedin);
 assert exists(select 1 from public.crm_attivita where lead_id=lead.id and tipo='messaggio_linkedin' and descrizione=lead.messaggio_linkedin),'Missing LinkedIn activity';
 assert (select stato from public.crm_leads where id=lead.id)='contattato';
 bad:=false;begin perform public.crm_mark_linkedin(lead.id,old_version,'Stale');exception when others then bad:=true;end;assert bad,'Stale review accepted';
 -- Notes alone protect BOTH fields, even when the current state remains da_contattare.
 update public.crm_leads set stato='da_contattare',note='Solo nota: conservare',updated_by=auth.uid() where id=lead.id;
 input:=jsonb_set(input,'{0,stato}','"cliente"');
 r:=public.crm_import_leads(input);
 assert (select stato='da_contattare' and note='Solo nota: conservare' from public.crm_leads where id=lead.id),'Note-only protection failed';
 r:=public.crm_import_leads(jsonb_set(input,'{0,settore}','"Non valido"'));assert (r->>'scartati')::int=1 and jsonb_array_length(r->'errori')=1;
 delete from public.crm_leads where id=lead.id;
 assert not exists(select 1 from public.crm_attivita where lead_id=lead.id),'Cascade did not clean fixtures';
end $$;
select set_config('request.jwt.claims','{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
do $$ declare bad boolean:=false;begin
 assert not public.crm_is_admin();assert not exists(select 1 from public.crm_leads),'Non-admin can read CRM';
 begin perform public.crm_import_leads('[]');exception when insufficient_privilege then bad:=true;end;assert bad,'Non-admin can import';
end $$;
set local role anon;
do $$ declare bad boolean:=false;begin
 begin perform 1 from public.crm_leads;exception when insufficient_privilege then bad:=true;end;assert bad,'Anonymous table access permitted';
end $$;
rollback;
select 'PASS: status history, activity note, protected reimport, follow-up, timestamps/actor, LinkedIn transaction, stale-version rejection, notes-only preservation, invalid enums, fixture cleanup/cascade, non-admin and anonymous restrictions; all fixtures rolled back.' as result;
