alter table public.portal_clients add column billing_details jsonb not null default '{}' check(jsonb_typeof(billing_details)='object');
create table public.portal_invoice_issuer(id text primary key default 'nexus' check(id='nexus'),details jsonb not null default '{}' check(jsonb_typeof(details)='object'));
alter table public.portal_invoice_issuer enable row level security;
create policy issuer_admin on public.portal_invoice_issuer for all to authenticated using (exists(select 1 from public.portal_admins where user_id=(select auth.uid()))) with check(exists(select 1 from public.portal_admins where user_id=(select auth.uid())));
grant select,insert,update on public.portal_invoice_issuer to authenticated;
revoke all on public.portal_invoice_issuer from anon;
insert into public.portal_invoice_issuer(details) values('{"legal_name":"Nexus S.r.l.","country":"IT"}');
create table public.portal_invoice_documents(
 id uuid primary key,client_id uuid not null references public.portal_clients(id),month_id uuid not null references public.portal_months(id),
 invoice_number text not null check(length(invoice_number) between 1 and 80),issue_date date not null,due_date date not null check(due_date>=issue_date),
 invoice_year integer generated always as (extract(year from issue_date)::integer) stored,
 snapshot jsonb not null check(jsonb_typeof(snapshot)='object'),net_amount numeric(14,2) not null,vat_rate numeric(5,2) not null,vat_amount numeric(14,2) not null,total_amount numeric(14,2) not null,
 object_path text not null unique,created_at timestamptz not null default now(),created_by uuid not null default auth.uid());
create unique index portal_invoice_number_year_unique on public.portal_invoice_documents(invoice_year,upper(regexp_replace(invoice_number,'\s','','g')));
create index portal_invoice_documents_client_date on public.portal_invoice_documents(client_id,issue_date desc);
create index portal_invoice_documents_month on public.portal_invoice_documents(month_id);
alter table public.portal_invoice_documents enable row level security;
create policy invoice_documents_read on public.portal_invoice_documents for select to authenticated using(exists(select 1 from public.portal_admins where user_id=(select auth.uid())) or exists(select 1 from public.portal_members where user_id=(select auth.uid()) and client_id=portal_invoice_documents.client_id));
create policy invoice_documents_insert on public.portal_invoice_documents for insert to authenticated with check(exists(select 1 from public.portal_admins where user_id=(select auth.uid())) and object_path=client_id::text||'/'||id::text||'.pdf');
grant select,insert on public.portal_invoice_documents to authenticated;
revoke all on public.portal_invoice_documents from anon;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('client-invoices','client-invoices',false,10485760,array['application/pdf']);
create policy invoice_pdf_read on storage.objects for select to authenticated using(bucket_id='client-invoices' and (exists(select 1 from public.portal_admins where user_id=(select auth.uid())) or exists(select 1 from public.portal_invoice_documents d where d.object_path=objects.name and exists(select 1 from public.portal_members pm where pm.user_id=(select auth.uid()) and pm.client_id=d.client_id))));
create policy invoice_pdf_insert on storage.objects for insert to authenticated with check(bucket_id='client-invoices' and exists(select 1 from public.portal_admins where user_id=(select auth.uid())) and exists(select 1 from public.portal_clients c where c.id::text=(storage.foldername(objects.name))[1]) and array_length(storage.foldername(objects.name),1)=1);
create policy invoice_pdf_cleanup on storage.objects for delete to authenticated using(bucket_id='client-invoices' and exists(select 1 from public.portal_admins where user_id=(select auth.uid())) and not exists(select 1 from public.portal_invoice_documents d where d.object_path=objects.name));
create or replace function public.portal_invoice_snapshot(p_month_id uuid,p_number text,p_issue date,p_due date,p_method text,p_notes text default '',p_preview boolean default false) returns jsonb language plpgsql security invoker set search_path='' as $$
declare m public.portal_months%rowtype;c public.portal_clients%rowtype;i jsonb;b jsonb; missing text[]:='{}';k text;net numeric;tax numeric;total numeric;begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501';end if;
 select * into m from public.portal_months where id=p_month_id;
 if m.id is null or not m.released or not m.workflow_managed then raise exception 'Conferma finale del mese necessaria prima di creare il documento';end if;
 select * into c from public.portal_clients where id=m.client_id;
 select details into i from public.portal_invoice_issuer where id='nexus';i:=coalesce(i,'{}');b:=c.billing_details;
 for k in select unnest(array['legal_name','address','postcode','city','country']) loop
 if nullif(trim(i->>k),'') is null then missing:=array_append(missing,'Nexus: '||k);end if;
 if nullif(trim(b->>k),'') is null then missing:=array_append(missing,'Cliente: '||k);end if;
 end loop;
 if nullif(trim(i->>'vat_number'),'') is null then missing:=array_append(missing,'Partita IVA Nexus');end if;
 if coalesce(nullif(trim(b->>'vat_number'),''),nullif(trim(b->>'tax_code'),'')) is null then missing:=array_append(missing,'Partita IVA / codice fiscale cliente');end if;
 if nullif(trim(p_number),'') is null then missing:=array_append(missing,'Numero fattura');end if;
 if p_issue is null then missing:=array_append(missing,'Data fattura');end if;
 if p_due is null then missing:=array_append(missing,'Scadenza pagamento');end if;
 if p_due<p_issue then raise exception 'La scadenza non può precedere la data fattura';end if;
 if nullif(trim(p_method),'') is null then missing:=array_append(missing,'Metodo di pagamento');end if;
 if length(coalesce(p_number,''))>80 or length(coalesce(p_method,''))>200 or length(coalesce(p_notes,''))>4000 then raise exception 'Testo troppo lungo';end if;
 if not p_preview and cardinality(missing)>0 then raise exception 'Completa i dati di fatturazione: %',array_to_string(missing,', ');end if;
 if m.invoice_lines is null or exists(select 1 from jsonb_array_elements(m.invoice_lines) where value->>'amount' is null) or m.vat_rate is null then raise exception 'Importi del mese incompleti';end if;
 select round(sum((value->>'amount')::numeric),2) into net from jsonb_array_elements(m.invoice_lines);
 tax:=round(net*m.vat_rate/100,2);total:=net+tax;
 return jsonb_build_object('schema_version',1,'month_id',m.id,'client_id',c.id,'client_name',c.name,'month',m.month,'invoice_number',trim(p_number),'issue_date',p_issue,'due_date',p_due,'payment_method',trim(p_method),'notes',coalesce(p_notes,''),'issuer',i,'customer',b,'lines',m.invoice_lines,'net_amount',net,'vat_rate',m.vat_rate,'vat_amount',tax,'total_amount',total,'minimum_logistics',m.minimum_logistics,'storage_scope',m.storage_scope,'quantities',jsonb_build_object('billable_shipments',m.billable_shipments,'shipped_pieces',m.shipped_pieces,'received_pieces',m.received_pieces,'stock_pieces',m.stock_pieces,'billable_returns',m.billable_returns,'created_shipments',m.created_shipments,'billable_m3',m.billable_m3),'validation_versions',m.validation_versions,'missing_fields',to_jsonb(missing));
end $$;
create or replace function public.portal_archive_invoice(p_id uuid,p_snapshot jsonb) returns uuid language plpgsql security invoker set search_path='' as $$
declare expected jsonb;target public.portal_months%rowtype;path text;begin
 if not exists(select 1 from public.portal_admins where user_id=(select auth.uid())) then raise exception 'Accesso riservato a Nexus' using errcode='42501';end if;
 select * into target from public.portal_months where id=(p_snapshot->>'month_id')::uuid for update;
 perform 1 from public.portal_clients where id=target.client_id for share;
 perform 1 from public.portal_invoice_issuer where id='nexus' for share;
 expected:=public.portal_invoice_snapshot(target.id,p_snapshot->>'invoice_number',(p_snapshot->>'issue_date')::date,(p_snapshot->>'due_date')::date,p_snapshot->>'payment_method',p_snapshot->>'notes',false);
 if expected is distinct from p_snapshot then raise exception 'Dati modificati durante la creazione: ricontrolla l’anteprima e riprova';end if;
 path:=target.client_id::text||'/'||p_id::text||'.pdf';
 if not exists(select 1 from storage.objects where bucket_id='client-invoices' and name=path and metadata->>'mimetype'='application/pdf' and (metadata->>'size')::bigint between 1 and 10485760) then raise exception 'PDF non caricato: riprova il salvataggio';end if;
 insert into public.portal_invoice_documents(id,client_id,month_id,invoice_number,issue_date,due_date,snapshot,net_amount,vat_rate,vat_amount,total_amount,object_path)
 values(p_id,target.client_id,target.id,expected->>'invoice_number',(expected->>'issue_date')::date,(expected->>'due_date')::date,expected,(expected->>'net_amount')::numeric,(expected->>'vat_rate')::numeric,(expected->>'vat_amount')::numeric,(expected->>'total_amount')::numeric,path);
 return p_id;
end $$;
revoke all on function public.portal_invoice_snapshot(uuid,text,date,date,text,text,boolean),public.portal_archive_invoice(uuid,jsonb) from public,anon;
grant execute on function public.portal_invoice_snapshot(uuid,text,date,date,text,text,boolean),public.portal_archive_invoice(uuid,jsonb) to authenticated;

revoke all on public.portal_invoice_documents from authenticated; grant select,insert on public.portal_invoice_documents to authenticated; revoke all on public.portal_invoice_issuer from authenticated; grant select,insert,update on public.portal_invoice_issuer to authenticated;
