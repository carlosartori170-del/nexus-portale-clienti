# Costi corrieri in attesa della fattura

In **Corrieri → Spedizioni Deagor senza costo corriere abbinato**, il pulsante **Inserisci importo** registra il costo totale IVA esclusa. Il cliente, la spedizione e il mese restano quelli dell'ordine Deagor. Il salvataggio atomico crea la riga in **Costi corrieri sostenuti da Nexus** e imposta lo stesso importo al cliente, senza ricarico. La riga sparisce dall'elenco senza costo ed è contrassegnata **Manuale · fattura da ricevere**.

Sono ammessi anche costi zero. Per modificare un importo usare **Modifica importo** sulla riga superiore. I clienti con gestione manuale o contratto proprio sono esclusi, come negli abbinamenti esistenti.

## Quando arriva la fattura

Importare la fattura lasciando da abbinare la riga relativa alla spedizione già coperta dal costo manuale. Sulla riga manuale scegliere **Sostituisci con fattura**, selezionare la riga importata e confermare. Il costo manuale viene rimosso e sostituito dal costo effettivo: non si sommano i due importi. Il riaddebito al cliente segue il nuovo costo IVA esclusa, senza maggiorazioni. Per Spediamo Pro si conserva la precisione dell'imponibile già scorporato.

Qualunque importo o sostituzione invalida la convalida Corrieri e riapre il riepilogo mensile tramite i trigger già presenti. Riconvalidare le sezioni richieste, aggiornare la prefattura e confermarla. I PDF storici non vengono modificati.

## Database e accessi

Applicare `database/manual-carrier-costs.sql` prima di pubblicare il frontend. Aggiunge il flag `manual_provisional`, un vincolo sulla destinazione, un indice univoco per costo manuale/spedizione, un trigger contro i doppi costi manuali/fattura e due RPC amministrative atomiche. Mantiene le RLS amministrative esistenti. Funzioni SECURITY INVOKER con search_path fisso, controllo portal_admins, nessuna esecuzione anonima.

Tutte le scritture verificano le copie attese delle righe e acquisiscono lock. In caso di cambiamento concorrente il modulo va riaperto. Il trigger protegge anche gli import e gli abbinamenti che scrivono direttamente nella tabella. I supplementi tra sole righe di fatture reali continuano a essere ammessi.

## Verifica

`npm run build` e `npm test`. `tests/manual-carrier.sql` verifica con fixture sintetiche creazione, prefattura, modifica, duplicati, snapshot scaduti, importi non validi, sostituzione senza doppio addebito e accessi. Esegue rollback completo. Prima dell'applicazione la migrazione è stata provata nello stesso tipo di transazione senza modifiche persistenti ai dati reali.
