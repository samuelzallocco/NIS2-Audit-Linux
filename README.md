# NIS2-Audit-Linux

🇮🇹 [Italiano](#italiano) · 🇬🇧 [English](#english)

---

## Italiano

Uno script senza grosse pretese, per un auditing non esaustivo di un sistema Linux, ai sensi della normativa europea NIS2 e linee guida ACN.

**`nis2_collect.sh` v1.2** - Raccolta evidenze di sicurezza per analisi NIS2 / ACN

### Caratteristiche

- **SOLA LETTURA**: non modifica nulla sul sistema (scrive solo nella dir di output)
- Non raccoglie hash di password, chiavi private, contenuto dei file applicativi
- Le righe di configurazione che contengono "password/secret/token/key" vengono oscurate (`<REDACTED>`) prima di essere salvate
- Compatibile con Debian/Ubuntu, RHEL/Rocky/Alma/CentOS/Fedora, SUSE
- Web server analizzati: Apache, Nginx, Lighttpd, Tomcat, Node.js (+ PHP-FPM / SimpleSAMLphp)
- Ultimo step: albero HTML navigabile delle web root (cartella `albero_web/`)
- Mostra a video l'avanzamento (passo N/totale, percentuale, tempo trascorso)

### Uso

```bash
sudo bash nis2_collect.sh [-o /percorso/NIS2_Audit_Report] [-w "/var/www /srv/www"] [-D] [-R] [-T] [-u URL]
```

| Opzione | Descrizione |
|---------|-------------|
| `-o`    | directory di output |
| `-w`    | web root da analizzare |
| `-D`    | no DB |
| `-R`    | refresh metadati dnf/yum |
| `-T`    | salta albero web root |
| `-u`    | URL base per i link dell'albero |

### Esempio

```bash
sudo bash nis2_collect.sh -o /home/zallocco/NIS2_Audit_Report -w "/var/www"
```

### Esito

Directory `nis2_audit_<versione>_<host>_<data>/` + archivio `.tar.gz` con SHA256

---

## English

A modest script for a non-exhaustive audit of a Linux system, in accordance with the European NIS2 directive and the Italian ACN (National Cybersecurity Agency) guidelines.

**`nis2_collect.sh` v1.2** - Security evidence collection for NIS2 / ACN analysis

### Features

- **READ-ONLY**: it does not modify anything on the system (it only writes to the output dir)
- It does not collect password hashes, private keys, or the contents of application files
- Configuration lines containing "password/secret/token/key" are redacted (`<REDACTED>`) before being saved
- Compatible with Debian/Ubuntu, RHEL/Rocky/Alma/CentOS/Fedora, SUSE
- Supported web servers: Apache, Nginx, Lighttpd, Tomcat, Node.js (+ PHP-FPM / SimpleSAMLphp)
- Final step: a browsable HTML tree of the web roots (`albero_web/` folder)
- Shows progress on screen (step N/total, percentage, elapsed time)

### Usage

```bash
sudo bash nis2_collect.sh [-o /path/NIS2_Audit_Report] [-w "/var/www /srv/www"] [-D] [-R] [-T] [-u URL]
```

| Option | Description |
|--------|-------------|
| `-o`   | output directory |
| `-w`   | web roots to analyze |
| `-D`   | skip DB |
| `-R`   | refresh dnf/yum metadata |
| `-T`   | skip web root tree |
| `-u`   | base URL for the tree links |

### Example

```bash
sudo bash nis2_collect.sh -o /home/zallocco/NIS2_Audit_Report -w
