# Canone mensile per fasce di spedizioni

Configurazione per clienti con una sola voce logistica basata sul numero di spedizioni. Il tariffario e i prezzi dei clienti sono nel database; nessun prezzo contrattuale viene inserito negli asset pubblici.

## Configurazione e uso

- In Scheda cliente → **Canone mensile per scaglioni**, configurare fasce consecutive da zero, con limiti inclusivi e canone fisso IVA esclusa. Descrizione, soglie e importi sono modificabili; si possono aggiungere ulteriori fasce.
- Il piano sostituisce l'unica voce logistica per i nuovi riepiloghi. Le fatture e i riepiloghi già salvati mantengono il loro piano; per cambiare un mese già salvato occorre scegliere **Usa tariffe attuali**.
- Convalidare le spedizioni del mese. Il registro giornaliero conta anche le uscite da giacenza secondo la data di spedizione.
- In Fatturazione il programma propone la fascia corrispondente, da confermare con **Scegli e applica scaglione**. Non applica un canone finché manca la scelta esplicita. Sono selezionabili solo fasce compatibili con il conteggio convalidato.
- La riga di fattura ha quantità **1**, tariffa e importo pari al canone. Le condizioni riportano fascia e spedizioni effettive. IVA, minimo logistico e sconti seguono i calcoli esistenti; non viene creata una nuova voce corriere.
- Anche con zero spedizioni occorre convalidare lo zero: la prima fascia può avere un canone positivo.
- Oltre l'ultima fascia non si estrapola un prezzo: aggiungere la fascia nella configurazione, usare le tariffe attuali e confermare la scelta.
- Ogni modifica al conteggio convalidato rende la scelta precedente non più attuale, anche se il numero resta nella stessa fascia. Riconvalidare, scegliere di nuovo e poi fare la conferma finale.

## Implementazione

Applicare insieme `database/shipment-tiers.sql` e `database/shipment-tier-calculation.sql` prima di pubblicare il frontend.

Nessuna nuova tabella o colonna e nessuna nuova policy: piano in `portal_clients.billing_rules` con modalità `tiered`; piano e scelta mensile in `portal_months.invoice_lines`, comprensivi di firma del conteggio e autore/data della scelta. Le RPC sono SECURITY INVOKER, amministratore obbligatorio per modifiche, search_path vuoto, privilegi espliciti senza accesso anonimo. Il validatore puro delle fasce non legge dati cliente.

La scelta blocca il mese con lo stesso advisory lock del flusso di fatturazione, confronta le righe/versioni attese e la firma della convalida corrente. Aggiorna soltanto la riga scelta e ricalcola la prefattura nella stessa transazione: errori su dati, minimo, IVA o sconto annullano l'intera modifica.

L'aggiornamento di `portal_build_preinvoice` introduce un ramo solo per `tiered`; gli altri calcoli restano invariati. Nessun aggiornamento automatico di mesi o PDF esistenti nella migrazione. L'eventuale configurazione iniziale del tariffario reale del cliente viene applicata separatamente, solo dopo autorizzazione, senza pubblicare prezzi contrattuali nel repository.

## Test

`npm test`, `npm run build`; test SQL sintetici in transazione con ROLLBACK. Coperti zero, confini delle fasce, canone non moltiplicato, IVA e snapshot PDF, scelta obbligatoria, disponibilità oltre ultima fascia, dati/conferme scaduti, storico invariato, refresh volontario, sconto e permessi. Ripetere anche le suite SQL di sconti e registro giornaliero dopo l'aggiornamento del calcolo.
