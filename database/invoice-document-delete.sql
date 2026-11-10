-- Removes only the selected courtesy copy; monthly billing data is unchanged.
grant delete on public.portal_invoice_documents to authenticated;
create policy invoice_documents_delete on public.portal_invoice_documents
for delete to authenticated using (
  exists(select 1 from public.portal_admins where user_id=(select auth.uid()))
);

create function public.portal_delete_invoice_document(p_id uuid,p_expected jsonb)
returns text language plpgsql security invoker set search_path='' as $$
declare target public.portal_invoice_documents%rowtype;
begin
  if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then
    raise exception 'Accesso riservato a Nexus' using errcode='42501';
  end if;
  if p_expected is null or p_expected->>'id' is distinct from p_id::text
     or p_expected->>'client_id' is null
     or p_expected->>'object_path' is distinct from
       (p_expected->>'client_id')::uuid::text||'/'||p_id::text||'.pdf' then
    raise exception 'Conferma documento non valida';
  end if;
  select * into target from public.portal_invoice_documents where id=p_id;
  -- Safe retry if the previous response was lost after the delete committed.
  if not found then return p_expected->>'object_path';end if;
  if p_expected is null or to_jsonb(target) is distinct from p_expected then
    raise exception 'Documento modificato: riapri la conferma di eliminazione';
  end if;
  if target.object_path is distinct from target.client_id::text||'/'||target.id::text||'.pdf' then
    raise exception 'Percorso PDF non valido';
  end if;
  delete from public.portal_invoice_documents d where d.id=p_id and to_jsonb(d)=p_expected;
  if not found then raise exception 'Documento modificato o già eliminato: aggiorna lo storico';end if;
  -- Storage files must be removed through the Storage API, never SQL.
  -- Existing invoice_pdf_cleanup permits admin deletion only after this row is gone.
  return target.object_path;
end;
$$;
revoke all on function public.portal_delete_invoice_document(uuid,jsonb) from public,anon;
grant execute on function public.portal_delete_invoice_document(uuid,jsonb) to authenticated;
