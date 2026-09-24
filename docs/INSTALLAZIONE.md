# Templar Wallet — Guida all'installazione (italiano)

Guida per chi deve **solo installare e usare** il wallet, su macOS, Windows,
Linux o Android. Se invece vuoi compilare dal codice sorgente, vai al
[`README.md`](../README.md) principale.

> ⚠️ **Solo testnet.** Templar Wallet lavora esclusivamente su Bitcoin testnet e
> Liquid testnet. Le monete che vedrai non hanno alcun valore e non esiste
> nessun percorso di spesa su mainnet. **Non inviare mai fondi reali.**

---

## 1. Requisiti

| Sistema | Requisiti minimi | Dipendenze da installare |
|---|---|---|
| **macOS** | macOS 10.15 (Catalina) o successivo — Apple Silicon o Intel | Nessuna |
| **Windows** | Windows 10 / 11 a 64 bit (x64) | Di norma nessuna; se manca `VCRUNTIME140.dll` vedi §4 |
| **Linux** | x86_64, glibc ≥ 2.35 → Ubuntu 22.04+, Debian 12+, Fedora 36+, Arch attuale | GTK 3 (`libgtk-3-0` / `gtk3`), quasi sempre già presente |
| **Android** | Android 7.0 o successivo | Nessuna |

Serve inoltre una **connessione a internet** (uscite TLS verso i server testnet
di Blockstream). Non servono account, chiavi API o registrazioni.

---

## 2. Scaricare il programma

Ogni versione viene compilata automaticamente da GitHub Actions e pubblicata
nella pagina **[Releases](https://github.com/0xMrtnz/TemplarWallet/releases/latest)**,
insieme a `SHA256SUMS.txt` per verificare i file. Scarica quello del tuo
sistema:

| Sistema | File |
|---|---|
| macOS | [`TemplarWallet-macos.dmg`](https://github.com/0xMrtnz/TemplarWallet/releases/latest/download/TemplarWallet-macos.dmg) |
| Windows | [`TemplarWallet-windows-x64-setup.exe`](https://github.com/0xMrtnz/TemplarWallet/releases/latest/download/TemplarWallet-windows-x64-setup.exe) (installer) oppure [`TemplarWallet-windows-x64.zip`](https://github.com/0xMrtnz/TemplarWallet/releases/latest/download/TemplarWallet-windows-x64.zip) (portabile) |
| Linux | [`TemplarWallet-linux-x64.tar.gz`](https://github.com/0xMrtnz/TemplarWallet/releases/latest/download/TemplarWallet-linux-x64.tar.gz) |
| Android (telefoni) | [`TemplarWallet-android-arm64.apk`](https://github.com/0xMrtnz/TemplarWallet/releases/latest/download/TemplarWallet-android-arm64.apk) |
| Android (emulatori) | [`TemplarWallet-android-x86_64.apk`](https://github.com/0xMrtnz/TemplarWallet/releases/latest/download/TemplarWallet-android-x86_64.apk) |

> Le build desktop non sono ancora firmate con un certificato a pagamento.
> macOS e Windows mostreranno quindi un avviso al primo avvio: i passaggi qui
> sotto spiegano come superarlo.

---

## 3. Installazione su macOS

La build non è ancora notarizzata da Apple, quindi macOS ne blocca il primo
avvio.

**Metodo 1 — Terminale (funziona sempre, fai questo per primo; obbligatorio su
macOS 26 Tahoe):**

```bash
xattr -c ~/Downloads/TemplarWallet-macos.dmg
open ~/Downloads/TemplarWallet-macos.dmg        # trascina Templar Wallet in Applicazioni
xattr -rc "/Applications/Templar Wallet.app"
open "/Applications/Templar Wallet.app"
```

L'opzione `-r` è necessaria: la quarantena viene messa anche sui file *dentro*
il bundle.

**Metodo 2 — Impostazioni di Sistema (macOS 15 Sequoia e precedenti):** apri
l'app una volta (verrà bloccata), poi **Impostazioni di Sistema → Privacy e
sicurezza**, scorri fino a *"Templar Wallet è stato bloccato…"* e clicca
**Apri comunque**.

La prima volta che usi **Scan QR**, macOS chiede l'accesso alla fotocamera:
concedilo.

---

## 4. Installazione su Windows

Due possibilità, scegli quella che preferisci.

### Con l'installer (consigliato)

1. Esegui `TemplarWallet-windows-x64-setup.exe`. È l'unica versione che
   registra i link `templar://` usati dal Templar Protocol.
2. SmartScreen mostra *"Windows ha protetto il PC"* perché la build non è
   firmata: clicca **Ulteriori informazioni → Esegui comunque**.
3. Segui la procedura guidata. L'app finisce in *Programmi* con collegamento nel
   menu Start (e sul desktop, se lo spunti).

### Versione portabile (zip)

1. Tasto destro sullo zip → **Estrai tutto…**, estrai in una cartella vera.
   **Non avviare l'app dalla finestra di anteprima dello zip**: servono tutti i
   file estratti (la cartella `data\` e le DLL) accanto all'eseguibile.
2. Apri la cartella estratta e fai doppio clic su **`templar_wallet.exe`**.
3. Anche qui SmartScreen avvisa: **Ulteriori informazioni → Esegui comunque**.

### Se l'app non parte

Errore su `VCRUNTIME140.dll` o `MSVCP140.dll` → installa il
[**Visual C++ Redistributable x64**](https://aka.ms/vs/17/release/vc_redist.x64.exe)
e riprova.

---

## 5. Installazione su Linux

1. Estrai l'archivio ed esegui `templar_wallet` dalla cartella estratta:
   ```bash
   tar xzf TemplarWallet-linux-x64.tar.gz
   ```
   La cartella estratta è autonoma: spostala dove vuoi, ma **tienila intera**
   (l'eseguibile carica `lib/libwallet_ffi.so` e i dati accanto a sé).
2. Unica dipendenza di sistema: **GTK 3**. Se il binario lamenta librerie
   mancanti:
   ```bash
   sudo apt install libgtk-3-0      # Debian / Ubuntu
   sudo dnf install gtk3            # Fedora
   ```
3. La build è compilata su Ubuntu 22.04, quindi richiede **glibc ≥ 2.35**. Un
   errore del tipo `` version `GLIBC_2.xx' not found `` significa che la tua
   distribuzione è più vecchia: in quel caso serve compilare dai sorgenti
   (vedi il [`README.md`](../README.md)).

### Voce nel menu applicazioni (opzionale)

```bash
cat > ~/.local/share/applications/templar-wallet.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Templar Wallet
Exec=/percorso/completo/templar_wallet
Icon=/percorso/completo/data/flutter_assets/assets/images/templar-wallet-logo.png
Categories=Finance;
Terminal=false
EOF
```

Sostituisci `/percorso/completo/` con la posizione reale della cartella
estratta.

---

## 5b. Installazione su Android

Scarica l'APK sul telefono e aprilo; alla prima installazione Android chiede di
consentire le installazioni dal browser o dal file manager. I telefoni usano il
file `arm64`, il file `x86_64` serve agli emulatori.

**Se avevi una build di test (0.1.0-alpha):** quegli APK erano firmati con una
chiave di sviluppo e Android non installa la 0.1.0 sopra di loro. Annota la
frase di recupero di ogni wallet presente sul telefono, disinstalla la vecchia
app (così i suoi wallet vengono cancellati dal telefono), installa la 0.1.0 e
ripristinali. Le build desktop di test si aggiornano senza problemi.

---

## 6. Hardware wallet (facoltativo)

Salta questa sezione se usi solo wallet software.

| Dispositivo | Cosa serve installare |
|---|---|
| **Ledger** (Nano S / S Plus / X / Stax / Flex) | Niente — driver nativo integrato, su tutti e tre i sistemi |
| **Blockstream Jade** (v1, v1.1, Plus) | Niente — driver nativo integrato |
| **Trezor, Coldcard, KeepKey, BitBox02** | Vengono **rilevati ma non pilotati**: serve `hwi` su Windows/Linux (`pipx install hwi` oppure `pip install hwi`, con `hwi` nel PATH). Su macOS non sono utilizzabili (la sandbox di sistema impedisce l'esecuzione di HWI). |

**Su Linux** i dispositivi USB appartengono a root finché non sono installate le
regole udev. L'app se ne accorge da sola: nella schermata hardware compare il
riquadro *"Device permissions needed"* con il pulsante **Fix device
permissions**, che installa le regole ufficiali con **una sola richiesta di
password** (`pkexec`). Dopo l'installazione **scollega e ricollega il
dispositivo**.

**Liquid con hardware wallet è supportato solo da Jade.** Con gli altri
dispositivi Liquid funziona in sola lettura (watch-only).

**Firma air-gap via QR:** la scansione con la fotocamera funziona su macOS e
Android. Su Windows e Linux importa la transazione firmata con le opzioni
**Paste** (incolla) o **File**. Su Android gli hardware wallet via USB non
sono supportati: usa la firma via QR.

---

## 7. Primo avvio

1. **Password dell'app.** Se crei o importi un wallet la cui frase di recupero
   viene salvata su questo dispositivo, Templar richiede una password: il
   contenuto viene cifrato a riposo (Argon2id + XChaCha20-Poly1305) e la
   password viene chiesta a ogni avvio (o sostituita da Touch ID / impronta,
   se li attivi). **Se la perdi, i wallet salvati non sono
   più recuperabili**: conserva sempre a parte, su carta, la frase di recupero
   di 12/24 parole. I wallet la cui chiave sta su un dispositivo hardware
   funzionano anche senza password.
2. **Crea un wallet**, apri **Receive** e copia un indirizzo.
3. **Prendi monete di test** gratuite dai faucet:
   - Bitcoin testnet: <https://coinfaucet.eu/en/btc-testnet/>
   - Liquid testnet (L-BTC e asset): <https://liquidtestnet.com/faucet> e
     <https://faucet.vulpem.com>
4. Attendi la sincronizzazione. La **prima** sincronizzazione Liquid fa una
   scansione completa e può richiedere qualche minuto.

---

## 8. Dove finiscono i dati (e come azzerare tutto)

| Sistema | Cartella dati wallet | File di configurazione |
|---|---|---|
| macOS | `~/Library/Containers/dev.templarwallet.templarWallet/Data/Library/Application Support/templar_wallet` | `templar_wallet.json` nella stessa cartella |
| Linux | `~/.local/share/templar_wallet` | `~/.config/templar_wallet.json` |
| Windows | `%APPDATA%\templar_wallet`, o la cartella scelta nell'installazione | `%APPDATA%\templar_wallet.json` |

Su Windows la procedura di installazione chiede dove tenere i dati dei wallet:
quella sopra è solo la scelta predefinita. Impostazioni → Vault & backup →
Storage mostra sempre la cartella realmente in uso.

Per ripartire da zero: chiudi l'app ed elimina quella cartella.

> **Attenzione:** cancellare la cartella dati elimina definitivamente i wallet di
> test e le loro frasi di recupero. Se un wallet contiene qualcosa che ti
> interessa, esporta prima la frase di recupero.

---

## 9. Problemi comuni

| Sintomo | Causa e soluzione |
|---|---|
| macOS: *"Apple non è riuscita a verificare…"* | Build non notarizzata → §3, metodo 1 |
| Windows: *"Windows ha protetto il PC"* | Build non firmata → **Ulteriori informazioni → Esegui comunque** |
| Windows: manca `VCRUNTIME140.dll` | Installa il [VC++ Redistributable x64](https://aka.ms/vs/17/release/vc_redist.x64.exe) |
| Linux: `error while loading shared libraries: libgtk-3.so.0` | `sudo apt install libgtk-3-0` (o `dnf install gtk3`) |
| Linux: `` version `GLIBC_2.xx' not found `` | Distribuzione più vecchia di Ubuntu 22.04 → compila dai sorgenti |
| L'hardware wallet non viene rilevato su Linux | Regole udev mancanti → pulsante **Fix device permissions**, poi ricollega il dispositivo |
| *"Bitcoin wallet not open"* subito dopo l'avvio | Un'altra istanza di Templar è già aperta: il database ammette un solo processo alla volta. Chiudi l'altra finestra. |
| L'app parte ma i saldi non si aggiornano | Manca l'accesso a internet, o un firewall blocca le connessioni TLS verso `electrum.blockstream.info` |

---

## 10. Segnalare un problema

Apri una issue su
<https://github.com/0xMrtnz/TemplarWallet/issues> indicando: sistema operativo e
versione, cosa stavi facendo, cosa ti aspettavi e cosa è successo (screenshot
benvenuti).

**Allega sempre il log**: `logs/templar.log` dentro la cartella dati della
tabella al §8 (più `templar.log.1`, se presente). Il log viene scritto su tutti
e tre i sistemi. In alternativa, per vedere gli errori a schermo:

- macOS: `/Applications/Templar\ Wallet.app/Contents/MacOS/templar_wallet` da Terminale
- Linux: avvia `templar_wallet` da terminale e copia l'output
- Windows: la build di release non scrive su console — allega il testo esatto
  dell'errore o uno screenshot

---

## 11. Limiti noti di questa versione

- **Solo testnet**, nessun percorso mainnet.
- La scansione QR con fotocamera è disponibile su macOS e Android; le opzioni
  **Paste** e **File** funzionano ovunque.
- Le transazioni Bitcoin segnalano RBF, ma manca ancora una schermata per
  aumentare la commissione.
- Su Liquid, un pagamento che muove un asset diverso da L-BTC non può ancora
  escludere le monete congelate: viene rifiutato finché non le scongeli.
- Con hardware wallet, Liquid è supportato **solo da Blockstream Jade**.
- Trezor, Coldcard, KeepKey e BitBox02 vengono rilevati ma non pilotati
  nativamente: richiedono `hwi` su Windows/Linux e non sono usabili su macOS.
- **Una sola istanza per volta** dell'applicazione.
- Le build desktop non sono ancora firmate né notarizzate.
