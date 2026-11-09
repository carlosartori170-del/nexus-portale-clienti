CREATE OR REPLACE FUNCTION public.portal_invoice_snapshot(p_month_id uuid, p_number text, p_issue date, p_due date, p_method text, p_notes text DEFAULT ''::text, p_preview boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
 if exists(select 1 from jsonb_array_elements(m.invoice_lines) r where r->>'basis'='billable_m3' and coalesce(r->>'mode','unit')<>'fixed' and ((r->>'quantity')::numeric is distinct from round((r->>'quantity')::numeric,2) or (r->>'amount')::numeric is distinct from case when r->>'mode'='included' then 0 else round(round((r->>'quantity')::numeric,2)*(r->>'rate')::numeric,2) end)) then raise exception 'Spazio occupato da ricalcolare: aggiorna la prefattura e conferma nuovamente. Quantità a due decimali e importo devono coincidere';end if;
 select round(sum((value->>'amount')::numeric),2) into net from jsonb_array_elements(m.invoice_lines);
 tax:=round(net*m.vat_rate/100,2);total:=net+tax;
 return jsonb_build_object('schema_version',1,'month_id',m.id,'client_id',c.id,'client_name',c.name,'month',m.month,'invoice_number',trim(p_number),'issue_date',p_issue,'due_date',p_due,'payment_method',trim(p_method),'notes',coalesce(p_notes,''),'issuer',i,'customer',b,'lines',m.invoice_lines,'net_amount',net,'vat_rate',m.vat_rate,'vat_amount',tax,'total_amount',total,'minimum_logistics',m.minimum_logistics,'storage_scope',m.storage_scope,'quantities',jsonb_build_object('billable_shipments',m.billable_shipments,'shipped_pieces',m.shipped_pieces,'received_pieces',m.received_pieces,'stock_pieces',m.stock_pieces,'billable_returns',m.billable_returns,'created_shipments',m.created_shipments,'billable_m3',m.billable_m3),'validation_versions',m.validation_versions,'missing_fields',to_jsonb(missing));
end $function$
;
