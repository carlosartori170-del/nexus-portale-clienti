# Periodo di gestione clienti

In **Scheda cliente → Modifica informazioni** si impostano **Data inizio gestione** e **Data fine gestione**. Entrambe sono inclusive; la fine vuota indica un rapporto ancora in corso. Se l'inizio è vuoto non viene applicato un limite iniziale, così i clienti esistenti mantengono il comportamento precedente fino alla compilazione delle date.

Il filtro usa l'intersezione tra periodo del cliente e mese selezionato. Un cliente attivo anche per un solo giorno del mese compare in quel mese; non compare nei mesi precedenti all'inizio o successivi alla fine. Il filtro non riproporziona tariffe o minimi e non cambia le quantità delle rilevazioni.

Il filtro predefinito riguarda scelta cliente, schede, fatturazione, convalide, riepiloghi, spazio, spedizioni, ricevimento, resi, trasporti e selezioni dei clienti nei corrieri. Le righe di costo corriere ancora da attribuire o interne Nexus restano visibili. Nell'archivio, gli amministratori possono includere esplicitamente clienti non attivi per consultarne schede, attività e documenti. Il cambio mese disattiva l'archivio e azzera le selezioni di clienti non più visibili.

La fatturazione mantiene sempre la lista dei soli clienti attivi, anche se l'archivio è stato aperto altrove. `portal_build_preinvoice` e `portal_validate_section` verificano anche sul database il periodo prima di generare prefatture o convalidare. Le importazioni riconoscono ancora tutte le anagrafiche per conservare e ricostruire dati storici. La modifica di una registrazione storica conserva il cliente originario nel selettore.

`database/client-period.sql` aggiunge due date nullable, il vincolo fine >= inizio e il controllo di attività nel mese, mantenendo RLS e autorizzazioni esistenti. Nessuna data viene assegnata o dedotta per clienti reali. Non vengono eliminati clienti né riscritti riepiloghi, importi o PDF precedenti.

Per la pubblicazione con i costi manuali applicare entrambe le migrazioni preparate (`client-period.sql` e `manual-carrier-costs.sql`), quindi il frontend. I due gruppi di test SQL sono passati separatamente con sole fixture sintetiche e rollback. Dopo l'applicazione definitiva eseguire entrambi i file di test sullo schema combinato, sempre con rollback.
