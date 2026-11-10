# Sconto concordato in fattura

In **Fatturazione**, preparare la prefattura e scegliere **Aggiungi sconto concordato**. Inserire un importo positivo IVA esclusa e, facoltativamente, una descrizione (massimo 500 caratteri). La voce vale per il solo cliente e mese selezionati. Per rimuoverla, aprire **Modifica sconto concordato** e impostare 0.

Lo sconto si applica dopo tutte le voci, inclusi l'eventuale minimo logistico, corrieri, imballi ed extra. Compare in dettaglio, riepilogo, export e PDF come riga negativa con quantità 1, etichetta **Sconto concordato** e descrizione. Il minimo logistico resta calcolato sui servizi prima dello sconto. L'imponibile, l'IVA e il totale vengono ricalcolati; è ammesso anche lo sconto dell'intero imponibile, con totale zero, ma non un totale negativo.

Il salvataggio verifica prefattura e sconto attesi, acquisisce il lock del cliente/mese, ricontrolla le convalide correnti e ricalcola tutto in una transazione. Un errore annulla anche la modifica dello sconto. Se minimo o IVA sono cambiati bisogna prima aggiornare e ricontrollare la prefattura. Un mese confermato torna in bozza e richiede una nuova conferma finale. I PDF già archiviati restano invariati. Aggiornare la prefattura o usare le tariffe attuali conserva lo sconto senza duplicarlo.

## Database

Applicare `database/invoice-discounts.sql` e `database/invoice-discount-calculation.sql`, in quest'ordine **nella stessa migrazione**, prima di pubblicare il frontend. La prima parte crea `portal_invoice_discounts`, RLS amministrativa, metadati di aggiornamento, invalidazione della conferma mensile e RPC di salvataggio. La seconda aggiorna il calcolo delle voci e dei requisiti. Le funzioni sono SECURITY INVOKER, con search_path fisso; nessun accesso anonimo. Gli utenti cliente vedono lo sconto soltanto nelle righe dei mesi confermati e nei loro documenti, secondo le RLS esistenti.

Nessuno sconto viene assegnato automaticamente ai clienti reali. Nessuna operazione sulle tabelle operative Dipendenti/Reparti/Attività.

## Verifica

Build e suite JS, incluso il controllo dei testi disegnati dal renderer PDF. `tests/invoice-discounts.sql` usa solo fixture sintetiche e rollback: minimo logistico e altre voci, IVA, conferma e snapshot PDF, modifica e rimozione, sconto totale, limiti, anteprime scadute, conservazione dopo aggiornamento tariffe e RLS. Prima della pubblicazione entrambe le parti della migrazione sono state provate insieme senza modifiche persistenti.
