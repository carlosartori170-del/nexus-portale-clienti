# Numero bolla nel registro giornaliero

In **Aggiungi registrazione** e **Modifica** si può indicare il numero della bolla di consegna. Campo testuale facoltativo, massimo 100 caratteri: conserva lettere, barre e zeri iniziali. Le registrazioni esistenti restano senza numero finché lo si inserisce manualmente.

Il numero compare nella tabella e nel CSV. In **Spedisci da giacenza** compare nella scelta del ricevimento e nelle note della nuova uscita insieme a data e fornitore. Il numero è registrato solo sul ricevimento originale: eventuali correzioni sul ricevimento si riflettono su tutte le uscite collegate. Sulla riga di uscita è di sola lettura.

Prima di pubblicare il frontend applicare `database/daily-delivery-note.sql`: aggiunge `delivery_note` con default vuoto e vincoli, aggiorna solo la RPC di salvataggio mantenendo controlli amministratore, snapshot, quantità, retry, SECURITY INVOKER e privilegi precedenti. I payload senza il nuovo campo conservano il numero già presente. Nessuna riscrittura dei dati precedenti o modifica alle policy RLS.

Verifiche: `npm test`, `npm run build`; DDL e `tests/daily-delivery-note.sql` in transazione con ROLLBACK, oltre alla suite SQL `tests/daily-stock.sql` per i flussi di giacenza e fatturazione. Solo fixture sintetiche.
