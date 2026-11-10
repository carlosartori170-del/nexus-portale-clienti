# Lettura degli inventari PDF Deagor

Il lettore usa le coordinate delle celle e le intestazioni della tabella: sku, ean (facoltativo), name, volume, height, width, length, total_qty e integration (facoltativa). Non presume che la quantità sia l'ultimo testo della riga. EAN e integration non vengono incorporati nella descrizione; i codici SKU con spazi vengono conservati.

Le celle di una riga possono continuare sulle righe successive senza scambiare i numeri della descrizione per quantità o volumi. Le intestazioni ripetute e i numeri pagina espliciti sono riconosciuti. Il lettore blocca quantità/volumi mancanti o ambigui, SKU duplicati, colonne non riconoscibili e PDF che mescolano clienti integration diversi. Non scarta righe danneggiate per produrre un totale parziale.

I totali continuano a usare inventoryItemsTotal e la sua precisione originale. La scelta del cliente e la conferma della data restano nell'anteprima, come prima. CSV, sostituzione delle rilevazioni e convalida dei mesi non cambiano.

La dipendenza pdfjs-dist rimane alla versione già utilizzata dall'app, 4.10.38, con gli stessi limiti di dimensione e pagine. Nessuna modifica al database. Il PDF originale dell'utente non viene modificato né inserito nel repository.

Verifica: npm run build, npm test, lettura locale del PDF reale con pdf.js 4.10.38 e confronto dei totali con Poppler e calcolo Decimal indipendente. I test nel repository contengono solo dati sintetici.
