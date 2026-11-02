# CRM Nexus

Il CRM estende il portale statico esistente senza introdurre un framework. Il menu è riservato agli amministratori già presenti in `portal_admins`. Andrea usa l'account amministratore concordato: non sono stati creati utenti, email, profili o tabelle accessi. Le modifiche sono attribuite all'account autenticato; `assegnato_a` identifica il commerciale.

## Accesso dopo il merge approvato

Aprire il portale, effettuare il login amministratore e scegliere **CRM**. Sono supportati i link `#/crm` e `#/crm/<uuid>` su GitHub Pages. Il filtro cliente/mese logistico non si applica al CRM.

Elenco e Kanban condividono filtri e ordinamento (priorità, follow-up crescente, date assenti in fondo). Il selettore di stato è disponibile anche da telefono. Un cambio stato fallito viene ripristinato nell'interfaccia; `updated_at` impedisce di sovrascrivere una modifica concorrente.

## Database e permessi

`database/crm.sql` aggiunge esclusivamente `crm_leads`, `crm_attivita`, indici, policy e funzioni CRM. Non modifica tabelle o policy esistenti. Tutte le funzioni sono `SECURITY INVOKER`, con `search_path` fisso. I trigger proteggono autore e timestamp e registrano i cambi di stato. Lo storico è consultabile e alimentabile dagli amministratori, senza modifiche retroattive dall'interfaccia.

RLS attivo su entrambe le tabelle. Le policy `crm_leads_admin`, `crm_attivita_admin_read` e `crm_attivita_admin_insert` richiedono il ruolo amministratore del portale. Nessun accesso anonimo o accesso per gli account cliente. Nessuna chiave segreta è stata aggiunta al frontend.

## CSV

Papa Parse 5.5.3 è vendorizzato localmente con licenza MIT. SHA-256 del file minificato: `3553fb8bdf5b8004ce5531e6827e81c8b34e7b3992677967754544064e97b016`.

Formato UTF-8, virgola, intestazioni nell'ordine indicato dalla specifica. BOM, virgolette e messaggi su più righe sono gestiti. La variante allegata inizialmente aveva un involucro aggiuntivo a punto e virgola: il recupero è applicato solo quando l'intestazione ne identifica esattamente il formato, e viene segnalato nell'anteprima.

L'upsert server `crm_import_leads` conserva **sia stato sia note** quando lo stato corrente è diverso da `da_contattare` **oppure** le note sono compilate. Il follow-up esistente non è incluso negli aggiornamenti dell'import. Gli errori sono riportati per riga. L'export usa i lead filtrati e protegge le celle che potrebbero essere interpretate come formule.

Il file reale dei lead non viene pubblicato nel repository. Prima consegna: 26 inseriti, 0 aggiornati, 0 scartati, tutti assegnati ad Andrea D'Onofrio.

## LinkedIn e attività

Il pulsante copia esclusivamente il messaggio salvato negli appunti. L'utente decide poi se segnare il lead come contattato; in caso di conferma, `crm_mark_linkedin` registra atomicamente stato e attività, controllando la versione del lead. Il link di ricerca apre manualmente LinkedIn in una nuova scheda. Il CRM non invia email, WhatsApp o messaggi LinkedIn e non effettua scraping.

## Verifiche

- `npm run build`: sintassi del JavaScript e risorse statiche.
- `npm test`: CSV, recupero dell'involucro, validazione, export, filtri, ordinamento e slug.
- `tests/crm-database.sql`: test su lead isolati con rollback, storico, note, reimportazione, attori, concorrenza e RLS. Richiede il contesto amministratore di test indicato nel file; non modifica lead reali.
- `tests/crm-browser.cjs`: controllo facoltativo in un runtime con Playwright già disponibile; usa soltanto fixture sintetiche e richieste Supabase intercettate. `CRM_CHROME` può indicare l'eseguibile Chromium. Verifica rollback ottimistico, scheda, attività, copia, Kanban, mobile e importazione.

Il workflow `CRM checks` esegue build statica e test unitari per il branch e la Pull Request. Non pubblica né effettua il merge.
