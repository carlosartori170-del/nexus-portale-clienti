# Giacenze nel registro giornaliero

Funzione disponibile per Japan Deal Store e gli altri clienti con conteggio manuale tramite registro giornaliero. Nessun cambiamento agli import Deagor o corrieri.

## Uso

1. In **Aggiungi registrazione**, compilare **Pezzi in giacenza**: sono i pezzi ancora da spedire, compresi nel campo **Numero di pezzi**. La quantità non può superare il numero di pezzi.
2. La tabella e l'export CSV mostrano **Giacenza attuale (pezzi)**, cioè il residuo disponibile oggi anche quando si consulta un mese passato. Le registrazioni già esistenti partono da zero: non si deducono quantità dai vecchi dati.
3. Se l'uscita avviene nello stesso mese, usare **Modifica**: ridurre la giacenza e aggiornare il numero di spedizioni effettuate.
4. Se l'uscita avviene in un mese successivo, selezionare il mese di uscita e **Spedisci da giacenza**. Scegliere una registrazione dei mesi precedenti, poi indicare data, pezzi da spedire e numero di spedizioni. Sono consentite uscite parziali e giacenze risalenti a più mesi prima.
5. La nuova riga riporta nelle note la data di ricevimento, il fornitore e il riferimento alla riga originale. Le eventuali note aggiuntive si conservano separatamente nel campo note utente. La nota di origine viene composta in visualizzazione e nell'export, dal collegamento persistente.
6. Per correggere un'uscita da giacenza, modificare la nuova riga. Ridurre i pezzi o eliminare l'uscita ripristina la disponibilità sulla riga originale. Il ricevimento originale non si elimina finché esistono uscite collegate; cliente, fornitore e date originali restano bloccati per mantenere il collegamento leggibile.

## Fatturazione

Si somma solo `shipment_count` in base a `shipped_on`, come prima. La giacenza non genera spedizioni né nuove voci tariffarie. Una nuova uscita in un mese successivo invalida solo la convalida spedizioni di quel mese, senza modificare la riga originale, il mese già confermato o i PDF archiviati. Modifiche esplicite alla registrazione originale seguono la normale riconvalida del relativo mese.

## Migrazione proposta

Applicare `database/daily-dispatch-stock.sql` prima della pubblicazione del frontend.

- Colonne additive in `portal_daily_dispatches`: `stock_pieces` (riserva originale, default 0) e `stock_source_id` (FK verso il ricevimento originale, DELETE RESTRICT), vincoli e indice sulla FK.
- Residuo = riserva originale meno i pezzi delle righe collegate, considerando tutti i mesi. Nessun aggiornamento automatico della riga originale quando si crea un'uscita: le firme delle convalide precedenti restano intatte.
- Trigger di controllo per tutte le scritture, comprese quelle dirette: blocco della riga originale durante il controllo della disponibilità; niente consumi oltre riserva, collegamenti tra clienti, catene di giacenze o uscite nello stesso mese.
- RPC SECURITY INVOKER per il salvataggio del registro e per l'uscita da giacenza, con controlli amministratore, confronto dei dati attesi, residuo atteso e identificativo stabile per ritentare una risposta persa senza duplicare la riga.
- Le policy RLS esistenti restano invariate: amministratore scrive, cliente legge soltanto le proprie righe. Nessuna nuova email o utenza e nessuna chiave segreta nel frontend.
- Nessuna riscrittura dei dati operativi preesistenti o delle fatture.

## Verifiche

`npm test` e `npm run build` verificano anche campi, selezione mesi/clienti, residuo tra mesi, salvataggio e retry, note, export e accesso amministratore.

Per i test database: BEGIN, DDL proposta, `tests/daily-stock.sql`, ROLLBACK. Le fixture sintetiche coprono uscite parziali ottobre/novembre/dicembre, quantità in prefatturazione, conservazione del mese originale confermato, disponibilità superata/scaduta, modifiche ed eliminazioni, ripristino residuo e RLS. Nessun dato o PDF reale viene modificato durante i test.
