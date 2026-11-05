# InPost e contratti corriere assegnati direttamente ai clienti

## Import

In Importazioni o Corrieri scegliere **Importa Excel InPost**. È supportato il dettaglio XLSX originale con packcode testuale, price, fuel_surcharge, invoicingMonth, customer_stored_date e delivery_zip_code.

L’anteprima richiede numero fattura e imponibile della fattura. Il totale del file deve coincidere con l’imponibile: price e fuel_surcharge sono euro IVA esclusa, sommati senza scorporo o maggiorazioni. Il numero documento viene registrato con prefisso INPOST; il codice pacco rimane una stringa completa, anche con 24 cifre.

Tracking univoci propongono una spedizione Deagor. Ogni riga può invece essere attribuita direttamente a un cliente registrato, segnata come spedizione interna Nexus o lasciata da abbinare. Non viene creato un ordine Deagor per i contratti diretti. Nessuna classificazione è dedotta dall’indicazione customer=NEXUS del file.

Gli Excel con indice ZIP incompleto possono essere recuperati in memoria se le parti necessarie sono integre. La segnalazione è visibile e serve una conferma esplicita del controllo delle righe. File privi delle parti necessarie vengono rifiutati. Sono ammessi al massimo 5 MB e 5000 righe; codici numerici arrotondati, duplicati ed errori bloccano il salvataggio.

Il salvataggio avviene in un solo POST, dopo una nuova verifica di spedizioni e costi già presenti. Reimportazioni identiche sono escluse; differenze nei costi devono essere verificate senza sovrascrivere il registro.

## Destinazione e fatturazione

Nel comando Abbina la destinazione è una sola: spedizione Deagor, cliente diretto, oppure Nexus. Per un cliente diretto il costo è conteggiato nella sezione Corrieri del **mese fattura corriere**, quindi nella prefattura dopo convalida, senza ricarico. Questo vale anche per clienti con quantità logistiche gestite manualmente.

Per una spedizione collegata a Deagor si usa invece il suo periodo di uscita; gli importi sulle spedizioni seguono il passaggio già esistente di proposta e conferma dei costi. I costi InPost sono già netti e non subiscono lo scorporo IVA usato per Spediamo Pro.

Cambiare il cliente destinatario invalida le convalide dei mesi interessati. Spostare un costo precedentemente legato a una spedizione con importo cliente richiede la conferma della rimozione dell’importo precedente. Nessun PDF già archiviato viene riscritto.

## Dipendenza

SheetJS CE 0.20.3 è vendorizzato da https://cdn.sheetjs.com/xlsx-0.20.3/package/dist/xlsx.full.min.js, con licenza Apache 2.0.

SHA-256: cc015130aa8521e7f088f88898eba949ccdcbfb38df0bd129b44b7273c3a6f41

## Rilascio

Applicare database/carrier-direct-client.sql su Supabase solo dopo approvazione. Eseguire tests/carrier-direct.sql con rollback. Pubblicare quindi il frontend e aggiornare la pagina. La migrazione aggiunge la destinazione diretta; non importa o riclassifica spedizioni esistenti.
