/* Date inclusive. Il mese di inizio e quello di fine restano visibili. */
function clientActiveInMonth(client,month){
 if(!client||!/^\d{4}-(0[1-9]|1[0-2])$/.test(String(month)))return false;
 return (!client.active_from||client.active_from.slice(0,7)<=month)&&(!client.active_until||client.active_until.slice(0,7)>=month);
}
function activeClients(){return state.clients.filter(c=>clientActiveInMonth(c,state.month))}
function clientArchiveVisible(){return !!state.admin&&!!state.showInactiveClients&&state.view!=='billing'}
function visibleClients(){return clientArchiveVisible()?state.clients:activeClients()}
function clientVisibleInMonth(id){const c=state.clients.find(c=>c.id===id);return !!c&&(clientArchiveVisible()||clientActiveInMonth(c,state.month))}
function clientsForSelection(value){const rows=visibleClients(),current=state.clients.find(c=>c.id===value);return current&&!rows.includes(current)?[...rows,current]:rows}
function ensureClientPeriodSelection(){
 if(state.admin&&state.client!=='all'&&!clientVisibleInMonth(state.client))state.client='all';
 if(typeof carrierTableFilters!=='undefined')for(const f of Object.values(carrierTableFilters))if(f.client&&!['all','unassigned'].includes(f.client)&&!clientVisibleInMonth(f.client))f.client='all';
}
function toggleClientArchive(){state.showInactiveClients=!state.showInactiveClients;shell()}
function clientPeriodFields(c){return field('active_from','Data inizio gestione',c.active_from,'date')+field('active_until','Data fine gestione',c.active_until,'date')+'<p class="wide muted">Le date sono incluse. Lascia la fine vuota per un cliente ancora in gestione. Senza data di inizio, il cliente è visibile anche nei mesi precedenti. I mesi di inizio e fine sono inclusi; le tariffe non vengono riproporzionate automaticamente.</p>'}
function clientPeriodValues(v){
 const from=v.active_from||null,until=v.active_until||null;
 for(const d of [from,until])if(d&&(!/^\d{4}-\d{2}-\d{2}$/.test(d)||!Number.isFinite(Date.parse(d))||new Date(d+'T00:00:00Z').toISOString().slice(0,10)!==d))throw Error('Data di gestione non valida');
 if(from&&until&&until<from)throw Error('La fine gestione non può precedere l’inizio');return {active_from:from,active_until:until};
}
function clientPeriodSummary(c){return 'Inizio: '+(c.active_from?date(c.active_from):'Non impostato')+' · Fine: '+(c.active_until?date(c.active_until):'In corso')+(clientActiveInMonth(c,state.month)?'':' · Fuori periodo nel mese selezionato')}
