# Eliminazione delle copie PDF archiviate

Solo l'amministratore vede **Elimina** accanto a **Visualizza / scarica PDF** nelle tabelle documenti (fatturazione, storico e scheda cliente).

La finestra mostra cliente, numero e data, e richiede una spunta di conferma. La cancellazione riguarda esclusivamente la copia di cortesia conservata nell'app: non annulla documenti sul portale ministeriale. Quantità, tariffe, importi, convalide e conferma del mese restano invariati. Dopo la cancellazione si può generare un nuovo PDF con lo stesso anno/numero, con un nuovo identificativo e file.

## Attivazione

Applicare `database/invoice-document-delete.sql` prima di pubblicare `index.html`. La migrazione aggiunge una policy DELETE amministratore e una RPC SECURITY INVOKER con search_path vuoto, controllo amministratore e confronto dell'intero documento atteso. Nessun dato reale viene cancellato dalla migrazione. Le policy esistenti di lettura e Storage restano invariate.

La RPC elimina il record applicativo e restituisce il percorso. Solo dopo questo passaggio il client rimuove il singolo oggetto con la Storage API; la policy esistente vieta di cancellare PDF ancora archiviati. Nessun DELETE SQL su storage.objects.

Le due API non sono una singola transazione: se la pulizia Storage fallisce, la finestra segnala che il documento è già rimosso dallo storico e permette di riprovare con **Elimina PDF**, senza ripetere il DELETE del record. Anche una risposta RPC persa si può ritentare. Chiudere la pagina durante un errore di pulizia può lasciare un file privato senza record: non impedisce la rigenerazione, ma richiede successiva pulizia amministrativa. Nessun altro PDF viene coinvolto.

## Verifica

- `npm test`: include conferma obbligatoria, accesso solo amministratore, snapshot immutabile, un solo file, errori RPC/Storage e retry.
- `npm run build`: verifica JavaScript e risorse.
- Test SQL: in una transazione, applicare la migrazione, eseguire `tests/invoice-document-delete.sql` e terminare con ROLLBACK. Crea solo fixture sintetiche; verifica RLS anche con DELETE diretto non amministratore, snapshot scaduto, cancellazione isolata, mese invariato e riutilizzo numero. Nessun PDF reale viene eliminato da questi test.
