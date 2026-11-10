function invoiceDiscountAmount(value){const raw=String(value??'').trim();if(!/^\d+(?:[.,]\d{1,2})?$/.test(raw))throw Error('Inserisci uno sconto IVA esclusa non negativo con massimo due decimali');const n=Number(raw.replace(',','.'));if(!Number.isFinite(n))throw Error('Sconto non valido');return n}
function invoiceDiscountSetting(cid,month=state.month){return (state.invoiceDiscounts||[]).find(d=>d.client_id===cid&&d.month.slice(0,7)===month)||null}
function invoiceDiscountForm(cid){
 if(!state.admin)return;const m=state.months.find(m=>m.client_id===cid&&inMonth(m.month)),c=state.clients.find(c=>c.id===cid),d=invoiceDiscountSetting(cid);
 if(!m?.workflow_managed)return toast('Prepara prima la prefattura dalle sezioni convalidate');
 if(!billingAllValid(cid))return toast('Convalida le sezioni richieste e aggiorna la prefattura prima dello sconto');
 if(Number(m.minimum_logistics)!==Number(c.minimum_logistics)||Number(m.vat_rate)!==Number(c.vat_rate))return toast('Minimo o IVA modificati: aggiorna prima la prefattura e ricontrolla gli importi');
 const base=sumConfigured(monthlyLines(m).filter(r=>r.basis!=='invoice_discount'),'amount');if(base==null)return toast('Completa tutte le tariffe prima dello sconto');
 showForm('Sconto concordato · '+esc(c.name),
  '<div class="wide"><p>'+esc(monthName(state.month))+' · imponibile prima dello sconto: <strong>'+money(base)+'</strong></p><p>Inserisci un importo positivo IVA esclusa. In fattura apparirà una riga negativa “Sconto concordato”, con la descrizione indicata. Lo sconto si applica dopo l’eventuale minimo logistico e riduce anche l’IVA.</p></div>'+
  field('discount_amount','Importo sconto IVA esclusa (€)',d?.amount??0,'number','required min="0" max="'+base+'" step="0.01"')+
  multiline('discount_description','Descrizione facoltativa da riportare in fattura (massimo 500 caratteri)',d?.description||'')+
  '<p class="wide muted">Per togliere uno sconto imposta 0. Il salvataggio aggiorna la prefattura e richiede una nuova conferma finale; i PDF già archiviati restano invariati.</p><label class="check wide"><input name="checked" type="checkbox" required>Confermo lo sconto per questo cliente e questo mese.</label>',async v=>{
   const amount=invoiceDiscountAmount(v.discount_amount),description=String(v.discount_description||'').trim();if(amount>base)throw Error('Lo sconto non può superare l’imponibile prima dello sconto');if(description.length>500)throw Error('Descrizione dello sconto troppo lunga');
   await api('rpc/portal_set_invoice_discount',{method:'POST',body:{p_client:cid,p_month:state.month+'-01',p_amount:amount,p_description:description,p_expected_lines:m.invoice_lines,p_expected_discount:d}});
  });
}
