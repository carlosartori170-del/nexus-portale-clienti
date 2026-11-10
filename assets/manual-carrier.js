/* Costi corriere inseriti prima dell'arrivo della fattura. */
function manualCarrierAmount(value){
 const raw=String(value??'').trim();
 if(!/^\d+(?:[.,]\d{1,2})?$/.test(raw))throw Error('Inserisci un importo IVA esclusa, con massimo due decimali');
 const amount=Number(raw.replace(',','.'));if(!Number.isFinite(amount))throw Error('Importo non valido');return amount;
}
function manualCarrierActions(c){
 if(c.manual_provisional)return '<button class="secondary small" onclick="manualCarrierCostForm(\''+c.shipment_id+'\',\''+c.id+'\')">Modifica importo</button> <button class="secondary small" onclick="replaceManualCarrierForm(\''+c.id+'\')">Sostituisci con fattura</button>';
 const linked=!!c.shipment_id||!!c.direct_client_id;
 return '<button class="secondary small" onclick="matchForm(\''+c.id+'\')">'+(c.nexus_owned?'Modifica destinazione':linked?'Modifica abbinamento':'Abbina / cliente / Nexus')+'</button>';
}
function manualCarrierCostForm(shipmentId,chargeId=null){
 if(!state.admin)return;
 const s=state.shipments.find(s=>s.id===shipmentId),c=chargeId?state.charges.find(c=>c.id===chargeId):null;
 if(!s||chargeId&&(!c?.manual_provisional||c.shipment_id!==s.id))return toast('Spedizione o costo non trovato: aggiorna la pagina');
 if(!spEligible(s)||state.clients.find(c=>c.id===s.client_id)?.billing_quantity_source==='manual')return toast('Cliente con contratto proprio / gestione manuale: verifica il costo');
 if(state.charges.some(row=>row.shipment_id===s.id&&row.id!==chargeId))return toast('La spedizione ha già un costo: aggiorna la pagina');
 showForm(c?'Modifica importo manuale':'Inserisci importo corriere',
  '<div class="wide"><p><strong>'+esc(clientName(s.client_id))+'</strong> · '+esc(s.code)+' · '+esc(s.recipient)+'</p><p>'+date(s.shipped_on)+' · '+esc(s.carrier)+' · tracking '+esc(s.tracking||'—')+'</p><p>Il cliente resta quello della spedizione. Questo importo sarà registrato nei costi corrieri e addebitato al cliente senza ricarico, nel mese della spedizione.</p></div>'+
  field('amount','Importo totale IVA esclusa (€)',c?Number(c.transport)+Number(c.fuel)+Number(c.extras):s.customer_charge??'','number','required min="0" step="0.01"')+
  '<div class="wide notice">Manuale · fattura da ricevere. L’IVA viene applicata nel riepilogo mensile. Quando arriva la fattura, importa il costo e usa Sostituisci con fattura su questa riga. Il salvataggio richiede una nuova convalida Corrieri e della prefattura; i PDF archiviati restano invariati.</div>'+
  (s.customer_charge!=null?'<p class="wide muted">Importo cliente attuale: '+money(s.customer_charge)+'. Verrà sostituito con l’importo inserito.</p>':'')+
  '<label class="check wide"><input name="checked" type="checkbox" required>Confermo l’importo IVA esclusa e il riaddebito al cliente della spedizione.</label>',async v=>{
   await api('rpc/portal_save_manual_carrier_cost',{method:'POST',body:{p_shipment:s.id,p_amount:manualCarrierAmount(v.amount),p_expected_shipment:s,p_charge:c?.id??null,p_expected_charge:c}});
  });
}
function manualCarrierReplacementCandidates(c){
 return state.charges.filter(a=>a.id!==c.id&&!a.manual_provisional&&!a.nexus_owned&&!a.direct_client_id&&!a.shipment_id)
  .sort((a,b)=>Number(b.reference===c.reference||b.carrier_code===c.reference)-Number(a.reference===c.reference||a.carrier_code===c.reference)||String(b.shipped_on).localeCompare(String(a.shipped_on)));
}
function replaceManualCarrierForm(id){
 if(!state.admin)return;const c=state.charges.find(c=>c.id===id),s=state.shipments.find(s=>s.id===c?.shipment_id);if(!c?.manual_provisional||!s)return toast('Costo manuale non trovato');
 const candidates=manualCarrierReplacementCandidates(c);if(!candidates.length)return toast('Importa prima la fattura: la riga da sostituire deve essere ancora da abbinare');
 showForm('Sostituisci costo manuale con fattura',
  '<div class="wide"><p><strong>'+esc(clientName(s.client_id))+'</strong> · '+esc(s.code)+' · '+esc(s.recipient)+'</p><p>Costo manuale attuale: '+money(Number(c.transport)+Number(c.fuel)+Number(c.extras))+'. Scegli la riga della fattura corrispondente: il suo costo sostituirà quello manuale.</p></div>'+
  '<div class="wide"><label for="manual_actual_charge">Riga importata da abbinare</label><select id="manual_actual_charge" name="actual_charge" required onchange="manualCarrierReplacementSummary()"><option value="">Seleziona la riga della fattura</option>'+candidates.map(a=>'<option value="'+a.id+'">'+esc(date(a.shipped_on)+' · '+a.invoice_number+' · '+a.recipient+' · '+a.reference+' · '+num(Number(a.transport)+Number(a.fuel)+Number(a.extras))+' € IVA esclusa')+'</option>').join('')+'</select><p id="manual_replacement_summary" class="notice">Seleziona una riga per verificare il nuovo importo.</p></div>'+
  '<p class="wide muted">I PDF archiviati restano invariati. La nuova fatturazione richiederà una nuova convalida.</p><label class="check wide"><input name="checked" type="checkbox" required>Ho verificato spedizione e fattura. Confermo la rimozione del costo manuale e il suo rimpiazzo con l’importo della fattura, senza sommarli. Riconvaliderò Corrieri e prefattura.</label>',async v=>{
   const actual=candidates.find(a=>a.id===v.actual_charge);if(!actual)throw Error('Seleziona la riga della fattura');
   await api('rpc/portal_replace_manual_carrier_cost',{method:'POST',body:{p_manual:c.id,p_actual:actual.id,p_expected_manual:c,p_expected_actual:actual,p_expected_shipment:s}});
  });
}
function manualCarrierReplacementSummary(){
 const a=state.charges.find(a=>a.id===document.getElementById('manual_actual_charge')?.value),box=document.getElementById('manual_replacement_summary');
 if(box)box.textContent=a?'Nuovo importo IVA esclusa da addebitare: '+num(Number(a.transport)+Number(a.fuel)+Number(a.extras))+' €. Il costo manuale verrà rimosso; i PDF archiviati restano invariati.':'Seleziona una riga per verificare il nuovo importo.';
}
