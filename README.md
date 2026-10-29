# NIS2-Audit-Linux

Uno script senza grosse pretese, per un auditing non esaustivo di un sistema Liunx, ai sensi della normativa europea NIS2 e linee guida ACN
(A modest script for a non-exhaustive audit of a Linux system, in accordance with the European NIS2 directive and Italian ACN guidelines.)

nis2_collect.sh v1.2 - Raccolta evidenze di sicurezza per analisi NIS2 / ACN

Vibe Coded by Samuel Zallocco With Claude, Revised by Gemini and Copilot

- SOLA LETTURA: non modifica nulla sul sistema (scrive solo nella dir di output)
- Non raccoglie hash di password, chiavi private, contenuto dei file applicativi
- Le righe di configurazione che contengono "password/secret/token/key" vengono
  oscurate (<REDACTED>) prima di essere salvate
- Compatibile con Debian/Ubuntu, RHEL/Rocky/Alma/CentOS/Fedora, SUSE
- Web server analizzati: Apache, Nginx, Lighttpd, Tomcat, Node.js (+ PHP-FPM / SimpleSAMLphp)
- Ultimo step: albero HTML navigabile delle web root (cartella albero_web/)
- Mostra a video l'avanzamento (passo N/totale, percentuale, tempo trascorso)

Uso:   sudo bash nis2_collect.sh [-o /percorso/NIS2_Audit_Report] [-w "/var/www /srv/www"] [-D] [-R] [-T] [-u URL]
       -D no DB | -R refresh metadati dnf/yum | -T salta albero web root | -u URL base per i link dell'albero

Esempio: sudo bash nis2_collect.sh -o /home/zallocco/NIS2_Audit_Report -w "/var/www"

Esito: directory nis2_audit_<versione>_<host>_<data>/ + archivio .tar.gz con SHA256
