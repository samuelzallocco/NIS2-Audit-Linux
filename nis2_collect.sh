#!/usr/bin/env bash
# =============================================================================
# nis2_collect.sh v1.2 - Raccolta evidenze di sicurezza per analisi NIS2 / ACN
# -----------------------------------------------------------------------------
# Vibe Coded by Samuel Zallocco With Claude, Revised by Gemini and Copilot
#
# - SOLA LETTURA: non modifica nulla sul sistema (scrive solo nella dir di output)
# - Non raccoglie hash di password, chiavi private, contenuto dei file applicativi
# - Le righe di configurazione che contengono "password/secret/token/key" vengono
#   oscurate (<REDACTED>) prima di essere salvate
# - Compatibile con Debian/Ubuntu, RHEL/Rocky/Alma/CentOS/Fedora, SUSE
# - Web server analizzati: Apache, Nginx, Lighttpd, Tomcat, Node.js (+ PHP-FPM / SimpleSAMLphp)
# - Ultimo step: albero HTML navigabile delle web root (cartella albero_web/)
# - Mostra a video l'avanzamento (passo N/totale, percentuale, tempo trascorso)
#
# Uso:   sudo bash nis2_collect.sh [-o /percorso/NIS2_Audit_Report] [-w "/var/www /srv/www"] [-D] [-R] [-T] [-u URL]
#        -D no DB | -R refresh metadati dnf/yum | -T salta albero web root | -u URL base per i link dell'albero
# Esempio: sudo bash nis2_collect.sh -o /home/zallocco/NIS2_Audit_Report -w "/var/www"
# Esito: directory nis2_audit_<versione>_<host>_<data>/ + archivio .tar.gz con SHA256
# =============================================================================

set -u
export LC_ALL=C
export PATH="$PATH:/usr/sbin:/sbin:/usr/local/sbin"

VERSION="1.2"
HOST="$(hostname -s 2>/dev/null || echo unknown)"
STAMP="$(date +%Y%m%d_%H%M%S)"
# Nome completo: il piu' lungo tra "hostname" e "hostname -f" (le due risposte possono divergere)
H1="$(hostname 2>/dev/null)"; H2="$(hostname -f 2>/dev/null)"
if [ "${#H2}" -gt "${#H1}" ]; then HOST_FQDN="$H2"; else HOST_FQDN="${H1:-$HOST}"; fi
OUTBASE="${HOME:-/root}"          # NON la directory corrente: evita di scrivere dentro una web root
WEBROOTS="/var/www /srv/www /srv/http /usr/share/nginx/html /opt"
SKIP_DB=0        # -D : non connettersi al database
ALLOW_REFRESH=0  # -R : consenti a dnf/yum di aggiornare la cache dei metadati (scrive in /var/cache, usa la rete)
SKIP_TREE=0      # -T : non generare l'albero HTML delle web root
TREE_BASEURL=""  # -u : URL base per i link dell'albero (default: https://<ServerName> o https://<hostname>)

while getopts "o:w:u:DRTh" opt; do
  case "$opt" in
    o) OUTBASE="$OPTARG" ;;
    w) WEBROOTS="$OPTARG" ;;
    D) SKIP_DB=1 ;;
    R) ALLOW_REFRESH=1 ;;
    T) SKIP_TREE=1 ;;
    u) TREE_BASEURL="$OPTARG" ;;
    h|*) echo "Uso: sudo bash $0 [-o dir_output] [-w \"webroot1 webroot2\"] [-D] [-R] [-T] [-u URL]"
         echo "  -D  non connettersi a MariaDB/MySQL"
         echo "  -R  consenti refresh cache metadati dnf/yum (default: solo cache locale)"
         echo "  -T  non generare l'albero HTML delle web root"
         echo "  -u  URL base per i link dell'albero (es. https://www.ateneo.it)"
         exit 0 ;;
  esac
done

# Bassa priorità CPU/IO per non pesare su sistemi in produzione
if [ -z "${NIS2_NICED:-}" ]; then
  export NIS2_NICED=1
  if command -v ionice >/dev/null 2>&1; then exec nice -n 19 ionice -c3 bash "$0" "$@"
  else exec nice -n 19 bash "$0" "$@"; fi
fi

OUT="${OUTBASE%/}/nis2_audit_${VERSION}_${HOST}_${STAMP}"
mkdir -p "$OUT" || { echo "Impossibile creare $OUT"; exit 1; }
chmod 700 "$OUT"
SUMMARY="$OUT/00_SUMMARY.txt"
: > "$SUMMARY"

IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1
[ "$IS_ROOT" -eq 0 ] && echo "ATTENZIONE: non sei root, molte evidenze saranno incomplete. Riesegui con sudo."

# ---------------------------------------------------------------- helper -----
have() { command -v "$1" >/dev/null 2>&1; }

# Oscura valori sensibili
redact() {
  sed -E 's/((pass(word|wd)?|secret|token|api[_-]?key|private[_-]?key|credential)[A-Za-z0-9_]*[[:space:]]*[=:][[:space:]]*).*/\1<REDACTED>/I'
}

# sec FILE "Titolo"  -> inizia/accoda sezione
CUR=""
sec() { CUR="$OUT/$1"; step "$2"; { echo; echo "=================== $2 ==================="; } >> "$CUR"; }

# run "comando"  -> esegue e accoda output (con timeout, errori inclusi)
run() {
  { echo "--- \$ $*"; timeout 60 bash -c "$*" 2>&1; echo; } >> "$CUR"
}
# runr -> come run ma con redazione segreti
runr() {
  { echo "--- \$ $*"; timeout 60 bash -c "$*" 2>&1 | redact; echo; } >> "$CUR"
}
# dump FILE -> accoda contenuto di un file (senza commenti/righe vuote), redatto
dump() {
  if [ -r "$1" ]; then
    { echo "--- FILE: $1"; grep -vE '^[[:space:]]*(#|;|$)' "$1" 2>/dev/null | redact; echo; } >> "$CUR"
  else
    echo "--- FILE: $1 (non presente o non leggibile)" >> "$CUR"
  fi
}
# flag LIVELLO "messaggio" -> riga nel summary
flag() { printf '[%-5s] %s\n' "$1" "$2" >> "$SUMMARY"; }

# note "testo" -> accoda una riga al file della sezione corrente
note() { echo "$*" >> "$CUR"; }

# ------------------------------------------------ indicatore di avanzamento ---
# step "titolo": stampa [N/TOT] percentuale e tempo trascorso; su terminale mostra anche uno spinner
# con i secondi del passo corrente, cosi' si vede che lo script lavora anche durante scansioni lunghe.
TOTAL_STEPS=18; STEP=0; SPIN_PID=""
IS_TTY=0; [ -t 1 ] && IS_TTY=1
spin_stop() {
  if [ -n "$SPIN_PID" ]; then
    kill "$SPIN_PID" 2>/dev/null; wait "$SPIN_PID" 2>/dev/null; SPIN_PID=""
    [ "$IS_TTY" -eq 1 ] && printf '\r\033[K'
  fi
}
step() {
  spin_stop
  STEP=$((STEP+1))
  printf '[%2d/%d] %3d%%  %s  (trascorsi %ds)\n' "$STEP" "$TOTAL_STEPS" $((STEP*100/TOTAL_STEPS)) "$1" "$SECONDS"
  if [ "$IS_TTY" -eq 1 ]; then
    (
      s0=$SECONDS; i=0
      while :; do
        case $((i % 4)) in 0) c='|' ;; 1) c='/' ;; 2) c='-' ;; *) c='\' ;; esac
        printf '\r        %s  in corso da %ds ...  ' "$c" $((SECONDS - s0))
        i=$((i+1)); sleep 0.4
      done
    ) &
    SPIN_PID=$!
  fi
}
trap 'spin_stop' EXIT
trap 'spin_stop; printf "\nInterrotto dall utente.\n"; exit 130' INT TERM

echo "nis2_collect.sh v$VERSION - output: $OUT"

# ============================================================ 01 SISTEMA =====
sec 01_sistema.txt "IDENTIFICAZIONE SISTEMA"
run "hostnamectl 2>/dev/null || hostname"
run "cat /etc/os-release"
run "lsb_release -a 2>/dev/null"
run "uname -a"
run "uptime; who -b"
run "systemd-detect-virt 2>/dev/null"
run "lscpu | head -20"
run "free -h"
run "date; timedatectl 2>/dev/null"

. /etc/os-release 2>/dev/null
OS_ID="${ID:-unknown}"; OS_VER="${VERSION_ID:-?}"; OS_NAME="${PRETTY_NAME:-unknown}"
FAMILY="other"
case "${ID_LIKE:-$OS_ID} $OS_ID" in
  *debian*|*ubuntu*) FAMILY="deb" ;;
  *rhel*|*fedora*|*centos*|*rocky*|*almalinux*) FAMILY="rpm" ;;
  *suse*|*sles*) FAMILY="suse" ;;
esac
flag INFO "Host: $HOST | OS: $OS_NAME | Kernel: $(uname -r) | Famiglia pkg: $FAMILY"
flag INFO "Uptime: $(uptime -p 2>/dev/null || uptime)"
flag TODO "Verifica EOL del sistema operativo su https://endoflife.date/$OS_ID (versione $OS_VER)"

# ====================================================== 02 PATCH / UPDATE ====
sec 02_patch_aggiornamenti.txt "PACCHETTI, REPOSITORY E LIVELLO DI PATCH"
case "$FAMILY" in
  deb)
    run "apt list --upgradable 2>/dev/null"
    run "apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null | grep -i '^Inst' | grep -i security"
    run "ls -la /etc/apt/sources.list /etc/apt/sources.list.d/ 2>&1"
    runr "grep -rhv '^#' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | grep -v '^$'"
    run "ls -la --time-style=full-iso /var/lib/apt/periodic/ 2>/dev/null"
    run "grep -E 'Start-Date|Commandline' /var/log/apt/history.log 2>/dev/null | tail -20"
    run "dpkg -l unattended-upgrades 2>/dev/null | tail -1"
    dump /etc/apt/apt.conf.d/20auto-upgrades
    dump /etc/apt/apt.conf.d/50unattended-upgrades
    run "dpkg -l > '$OUT/pacchetti_installati.txt' 2>&1; wc -l < '$OUT/pacchetti_installati.txt'"
    [ -f /var/run/reboot-required ] && flag WARN "Riavvio richiesto (/var/run/reboot-required): kernel/librerie aggiornate non attive"
    UPG=$(apt list --upgradable 2>/dev/null | grep -vc '^Listing')
    SECUPG=$(apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null | grep -i '^Inst' | grep -ci security)
    flag INFO "Pacchetti aggiornabili (cache apt locale): $UPG | di cui security: $SECUPG"
    [ "${UPG:-0}" -gt 0 ] && flag WARN "Esistono aggiornamenti non applicati ($UPG). Esegui 'apt update' prima per un dato accurato."
    dpkg -l unattended-upgrades >/dev/null 2>&1 || flag WARN "unattended-upgrades non installato: nessun patching automatico di sicurezza"
    ;;
  rpm)
    PM="yum"; have dnf && PM="dnf"
    [ "$ALLOW_REFRESH" -eq 0 ] && PM="$PM -C"   # cache-only: nessuna scrittura in /var/cache, nessun accesso di rete
    [ "$ALLOW_REFRESH" -eq 0 ] && echo "NOTA: dati da cache locale dnf/yum (potrebbero essere datati). Usa -R per aggiornare i metadati." >> "$CUR"
    run "$PM -q check-update --security 2>/dev/null | head -100"
    run "$PM -q updateinfo summary 2>/dev/null"
    run "$PM -q updateinfo list security 2>/dev/null | head -100"
    run "$PM repolist -v 2>&1 | grep -E 'Repo-id|Repo-name|Repo-baseurl|Repo-status' "
    run "$PM history list 2>/dev/null | head -25"
    run "rpm -qa --last | head -30"
    run "needs-restarting -r 2>&1"
    run "needs-restarting -s 2>&1 | head -30"
    run "systemctl is-enabled dnf-automatic.timer dnf-automatic-install.timer yum-cron 2>&1"
    dump /etc/dnf/automatic.conf
    run "rpm -qa | sort > '$OUT/pacchetti_installati.txt'; wc -l < '$OUT/pacchetti_installati.txt'"
    SECUPG=$($PM -q check-update --security 2>/dev/null | grep -Ec '^[A-Za-z0-9_.+-]+\.[A-Za-z0-9_]+[[:space:]]')
    flag INFO "Pacchetti con aggiornamento di SICUREZZA pendente: $SECUPG"
    [ "${SECUPG:-0}" -gt 0 ] && flag FAIL "Patch di sicurezza non applicate: $SECUPG pacchetti"
    needs-restarting -r >/dev/null 2>&1 || flag WARN "Riavvio richiesto (needs-restarting -r)"
    ;;
  suse)
    run "zypper --non-interactive lp 2>&1 | head -60"
    run "zypper lr -u 2>&1"
    run "rpm -qa --last | head -30"
    run "rpm -qa | sort > '$OUT/pacchetti_installati.txt'"
    ;;
  *) run "echo 'Famiglia distribuzione non riconosciuta: raccolta pacchetti saltata'" ;;
esac
# Kernel installato vs in esecuzione
run "echo 'Kernel in esecuzione:' \$(uname -r); ls -1 /boot/vmlinuz* 2>/dev/null"
run "livepatch status 2>/dev/null; kpatch list 2>/dev/null"

# ====================================================== 03 MAC (SELinux) =====
sec 03_selinux_apparmor.txt "SELINUX / APPARMOR / FIPS"
if have getenforce; then
  SE="$(getenforce 2>/dev/null)"
  run "getenforce"
  run "sestatus"
  dump /etc/selinux/config
  run "getsebool -a 2>/dev/null | grep -E 'httpd_|mysql_|nis_enabled'"
  run "ps -eZ 2>/dev/null | grep -E 'httpd|apache|mysqld|mariadbd|sshd' | sort -u | head -20"
  if [ "$IS_ROOT" -eq 1 ] && have ausearch; then
    run "ausearch -m avc -ts this-week 2>/dev/null | grep -c 'type=AVC'"
  fi
  case "$SE" in
    Enforcing) flag OK   "SELinux: Enforcing" ;;
    Permissive) flag FAIL "SELinux: Permissive (non applica le policy)" ;;
    Disabled)   flag FAIL "SELinux: Disabled" ;;
  esac
else
  echo "SELinux non installato" >> "$CUR"
  flag INFO "SELinux non presente"
fi
if have aa-status; then
  run "aa-status 2>&1 | head -40"
  flag INFO "AppArmor presente (vedi 03_selinux_apparmor.txt)"
fi
run "cat /proc/sys/crypto/fips_enabled 2>/dev/null"
run "update-crypto-policies --show 2>/dev/null"

# ============================================================ 04 RETE ========
sec 04_rete_firewall.txt "RETE, PORTE IN ASCOLTO, FIREWALL"
run "ip -br addr"
run "ip route"
run "ss -tulpn"
dump /etc/resolv.conf
run "cat /proc/sys/net/ipv4/ip_forward"
run "firewall-cmd --state 2>&1; firewall-cmd --list-all-zones 2>&1 | head -80"
run "ufw status verbose 2>&1"
# iptables/nft vengono interrogati solo se il modulo kernel e' gia' caricato (evita autoload di moduli)
MODS="$(lsmod 2>/dev/null)"
echo "$MODS" | grep -q '^nf_tables' && run "nft list ruleset 2>&1 | head -150"
echo "$MODS" | grep -q '^ip_tables' && run "iptables -S 2>&1 | head -100"
echo "$MODS" | grep -q '^ip6_tables' && run "ip6tables -S 2>&1 | head -50"
FW=0
{ have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; } && FW=1
{ have ufw && ufw status 2>/dev/null | grep -q 'Status: active'; } && FW=1
{ have nft && echo "$MODS" | grep -q '^nf_tables' && [ "$(nft list ruleset 2>/dev/null | wc -l)" -gt 5 ]; } && FW=1
{ have iptables && echo "$MODS" | grep -q '^ip_tables' && [ "$(iptables -S 2>/dev/null | wc -l)" -gt 4 ]; } && FW=1
[ "$FW" -eq 1 ] && flag OK "Firewall host attivo con regole" || flag FAIL "Nessun firewall host attivo rilevato"
if have ss; then
  PUB=$(ss -H -tuln 2>/dev/null | awk '{print $5}' | grep -E '^(0\.0\.0\.0|\[::\]|\*):' | sed 's/.*://' | sort -un | tr '\n' ' ')
  flag INFO "Porte in ascolto su tutte le interfacce: ${PUB:-nessuna}"
  echo "$PUB" | grep -qwE '3306' && flag FAIL "MariaDB (3306) in ascolto su tutte le interfacce"
  echo "$PUB" | grep -qwE '21|23' && flag FAIL "Servizio in chiaro in ascolto (FTP/Telnet)"
fi

# ======================================================== 05 SSH & ACCOUNT ===
sec 05_ssh_account_accessi.txt "SSH, ACCOUNT, PRIVILEGI, POLICY PASSWORD"
if have sshd && [ "$IS_ROOT" -eq 1 ]; then
  run "sshd -T 2>&1 | grep -E '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|permitemptypasswords|x11forwarding|maxauthtries|logingracetime|clientaliveinterval|clientalivecountmax|ciphers|macs|kexalgorithms|protocol|allowusers|allowgroups|usepam|loglevel|banner|maxsessions)'"
  PRL=$(sshd -T 2>/dev/null | awk '/^permitrootlogin/{print $2}')
  PWA=$(sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2}')
  [ "$PRL" = "yes" ] && flag FAIL "SSH: PermitRootLogin yes"
  [ "$PWA" = "yes" ] && flag WARN "SSH: PasswordAuthentication yes (valutare solo chiavi + MFA)"
else
  dump /etc/ssh/sshd_config
fi
run "ls -la /etc/ssh/sshd_config.d/ 2>/dev/null"
run "awk -F: '\$3==0{print \"UID0:\",\$1}' /etc/passwd"
run "awk -F: '\$7 !~ /(nologin|false|sync|shutdown|halt)\$/ {print \$1\":\"\$3\":\"\$7}' /etc/passwd"
if [ "$IS_ROOT" -eq 1 ]; then
  run "awk -F: '(\$2==\"\"){print \"PASSWORD VUOTA:\",\$1}' /etc/shadow"
  EMPTY=$(awk -F: '($2==""){c++}END{print c+0}' /etc/shadow)
  [ "$EMPTY" -gt 0 ] && flag FAIL "Account con password vuota: $EMPTY"
  run "for u in \$(awk -F: '\$7 !~ /(nologin|false)\$/ {print \$1}' /etc/passwd); do echo \"== \$u\"; chage -l \$u 2>/dev/null | grep -E 'Last password|Password expires|Maximum'; done"
  run "awk -F: '\$2 ~ /^\\\$(1|5)\\\$/ {print \"HASH DEBOLE (MD5/SHA256):\",\$1}' /etc/shadow"
fi
UID0=$(awk -F: '$3==0' /etc/passwd | wc -l)
[ "$UID0" -gt 1 ] && flag FAIL "Più account con UID 0: $UID0"
run "getent group sudo wheel adm root docker 2>/dev/null"
runr "grep -rhvE '^[[:space:]]*(#|$)' /etc/sudoers /etc/sudoers.d/ 2>/dev/null"
run "grep -E '^(PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_MIN_LEN|PASS_WARN_AGE|ENCRYPT_METHOD|UMASK|SHA_CRYPT)' /etc/login.defs"
dump /etc/security/pwquality.conf
dump /etc/security/faillock.conf
run "ls /etc/pam.d/; grep -hE 'pam_pwquality|pam_cracklib|pam_faillock|pam_tally2|pam_google_authenticator|pam_u2f|pam_duo|pam_sss|pam_ldap|pam_krb5|pam_oath' /etc/pam.d/* 2>/dev/null | sort -u"
run "last -n 25 -F 2>/dev/null"
run "lastb -n 10 2>/dev/null | head -12"
run "lastlog 2>/dev/null | grep -v 'Never logged' | head -30"
run "find /home /root -maxdepth 3 -name authorized_keys -exec ls -la {} \\; 2>/dev/null"
grep -rqsE 'pam_google_authenticator|pam_u2f|pam_duo|pam_oath' /etc/pam.d/ || flag WARN "Nessun modulo MFA PAM rilevato (verificare MFA per accessi privilegiati)"

# ======================================================== 06 LOG / AUDIT =====
sec 06_logging_audit_tempo.txt "LOGGING, AUDIT, SINCRONIZZAZIONE ORARIA"
run "systemctl is-active rsyslog syslog-ng systemd-journald auditd chronyd chrony ntp ntpd systemd-timesyncd 2>&1"
dump /etc/rsyslog.conf
run "grep -rhE '^[^#]*@' /etc/rsyslog.d/ /etc/rsyslog.conf 2>/dev/null"
dump /etc/systemd/journald.conf
run "ls -la /var/log/journal 2>&1 | head -3"
run "auditctl -s 2>&1; auditctl -l 2>&1 | head -80"
dump /etc/audit/auditd.conf
run "du -sh /var/log 2>/dev/null; ls -la /var/log | head -50"
dump /etc/logrotate.conf
run "chronyc tracking 2>&1; chronyc sources 2>&1 | head -10"
run "timedatectl timesync-status 2>&1"
run "ntpq -p 2>&1 | head"
if grep -rqsE '^[^#]*(@@?[A-Za-z0-9.\[]|omfwd|target=)' /etc/rsyslog.conf /etc/rsyslog.d/ 2>/dev/null || have wazuh-control || [ -d /var/ossec ] || [ -d /opt/splunkforwarder ] || have filebeat || have fluentd || have promtail; then
  flag OK "Possibile inoltro log remoto/agente SIEM rilevato"
else
  flag WARN "Nessun inoltro log centralizzato rilevato (richiesto: logging centralizzato e conservazione)"
fi
systemctl is-active auditd >/dev/null 2>&1 && flag OK "auditd attivo" || flag WARN "auditd non attivo"
{ systemctl is-active chronyd chrony systemd-timesyncd ntp ntpd 2>/dev/null | grep -q '^active'; } && flag OK "Sincronizzazione oraria attiva" || flag WARN "Nessun servizio NTP attivo"
[ -d /var/log/journal ] || flag INFO "Journal non persistente (/var/log/journal assente)"

# ===================================================== 07 SERVIZI / CRON =====
sec 07_servizi_cron.txt "SERVIZI, TIMER, CRON"
run "systemctl list-units --type=service --state=running --no-pager 2>/dev/null"
run "systemctl list-unit-files --type=service --state=enabled --no-pager 2>/dev/null"
run "systemctl list-timers --all --no-pager 2>/dev/null | head -30"
run "ls -la /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly 2>&1"
runr "cat /etc/crontab 2>/dev/null"
runr "for u in \$(cut -d: -f1 /etc/passwd); do c=\$(crontab -l -u \$u 2>/dev/null | grep -v '^#'); [ -n \"\$c\" ] && echo \"## \$u\" && echo \"\$c\"; done"

# ============================================ 08 FILESYSTEM / CIFRATURA ======
sec 08_filesystem_cifratura_hardening.txt "FILESYSTEM, CIFRATURA, HARDENING KERNEL"
run "df -hT"
run "lsblk -f"
run "mount | grep -E ' /(tmp|var|var/tmp|home|dev/shm) '"
dump /etc/fstab
run "lsblk -o NAME,TYPE,FSTYPE | grep -Ei 'crypt|luks'"
run "cryptsetup status \$(lsblk -nro NAME,TYPE | awk '\$2==\"crypt\"{print \$1}' | head -1) 2>&1 | head"
lsblk -o TYPE,FSTYPE 2>/dev/null | grep -qiE 'crypt|luks' && flag OK "Volumi cifrati (LUKS) presenti" || flag INFO "Nessun volume LUKS rilevato (cifratura a riposo da verificare a livello storage/hypervisor)"
run "sysctl -a 2>/dev/null | grep -E '^(kernel.randomize_va_space|kernel.kptr_restrict|kernel.dmesg_restrict|kernel.yama.ptrace_scope|fs.suid_dumpable|net.ipv4.conf.all.rp_filter|net.ipv4.conf.all.accept_redirects|net.ipv4.conf.all.send_redirects|net.ipv4.conf.all.accept_source_route|net.ipv4.tcp_syncookies|net.ipv4.icmp_echo_ignore_broadcasts|net.ipv6.conf.all.accept_ra|net.ipv6.conf.all.accept_redirects) '"
run "find / -xdev -type f -perm -4000 2>/dev/null | head -60"
run "find /etc /usr /var /opt -xdev -type f -perm -0002 2>/dev/null | head -40"
run "find / -xdev \\( -nouser -o -nogroup \\) 2>/dev/null | head -20"
run "ls -la /etc/passwd /etc/shadow /etc/group /etc/gshadow /etc/ssh/sshd_config /etc/sudoers"
run "openssl version"
run "ls /etc/ssl/certs 2>/dev/null | wc -l"
for t in aide tripwire rkhunter chkrootkit clamd clamav-daemon fail2ban wazuh-agent ossec falco osqueryd sssd crowdstrike falcon-sensor sentinelone mdatp; do
  { systemctl list-unit-files 2>/dev/null | grep -q "^$t" || have "$t"; } && echo "$t" >> "$OUT/.sec_tools"
done
if [ -f "$OUT/.sec_tools" ]; then
  run "echo 'Strumenti di sicurezza rilevati:'; cat '$OUT/.sec_tools'"
  flag INFO "Strumenti sicurezza rilevati: $(tr '\n' ' ' < "$OUT/.sec_tools")"; rm -f "$OUT/.sec_tools"
else
  flag WARN "Nessun FIM/AV/EDR/fail2ban rilevato (aide, clamav, wazuh, fail2ban, EDR...)"
fi

# ============================================== 09 WEB / APPLICATION SERVER ==
sec 09_webserver.txt "WEB SERVER: APACHE / NGINX / LIGHTTPD / TOMCAT / NODE.JS"

# --- helper locali -----------------------------------------------------------
# cgrep REGEX DIR...  -> righe NON commentate che combaciano (case-insensitive)
cgrep() { local re="$1"; shift; grep -rhiE "$re" "$@" 2>/dev/null | grep -vE '^[[:space:]]*(#|;|//)'; }
# cgrep_sum REGEX DIR... -> come cgrep ma raggruppa e conta le righe uguali (segreti oscurati)
cgrep_sum() { local re="$1"; shift; cgrep "$re" "$@" | sed -E 's/^[[:space:]]+//' | sort | uniq -c | sort -rn | head -80 | redact; }
# oscura gli attributi XML sensibili (password="..", keystorePass="..", secret="..")
redact_xml() { sed -E 's/secretRequired=/ZZKEEPSR=/g; s/([A-Za-z]*(pass|secret|credential|token)[A-Za-z]*)="[^"]*"/\1="<REDACTED>"/Ig; s/ZZKEEPSR=/secretRequired=/g'; }
# oscura i parametri sensibili nelle righe di comando (--password xxx, --token=xxx)
redact_args() { sed -E 's/(--?(password|passwd|pass|pwd|token|secret|api[-_]?key|key|auth)[= ]+)[^ ]+/\1<REDACTED>/Ig'; }
# toglie i commenti XML (anche multilinea); se manca perl lascia il file com'e'
xml_nocomments() { if have perl; then perl -0777 -pe 's/<!--.*?-->//gs' "$1" 2>/dev/null; else cat "$1" 2>/dev/null; fi; }

# --- estrazione DocumentRoot -> file TSV "percorso<TAB>servername<TAB>server" --
docroots_apache() {
  find -L "$@" -type f 2>/dev/null | while read -r f; do
    awk '
      { line=$0; sub(/^[ \t]+/,"",line); if (line ~ /^#/ || line=="") next
        k=tolower(line)
        if (k ~ /^<virtualhost/)  { inv=1; sn=""; dr=""; next }
        if (k ~ /^<\/virtualhost/) { if (dr!="") print dr "\t" (sn==""?"-":sn) "\tapache"; inv=0; sn=""; dr=""; next }
        n=split(line,a,/[ \t]+/); key=tolower(a[1])
        if (key=="servername") { sn=a[2]; sub(/:[0-9]+$/,"",sn) }
        if (key=="documentroot") { v=a[2]; gsub(/"/,"",v); if (inv) dr=v; else print v "\t-\tapache" }
      }' "$f"
  done
}
docroots_nginx() {
  find -L "$@" -type f 2>/dev/null | while read -r f; do
    awk '
      { line=$0; sub(/#.*/,"",line); sub(/^[ \t]+/,"",line); if (line=="") next
        d0=depth
        if (!ins && line ~ /^server[ \t]*\{/) { ins=1; sd=d0; sn=""; dr=""; dr2="" }
        if (ins) {
          n=split(line,a,/[ \t;]+/)
          if (a[1]=="server_name" && sn=="") sn=a[2]
          if (a[1]=="root") { v=a[2]; gsub(/["\047]/,"",v); if (d0==sd+1 && dr=="") dr=v; else if (dr2=="") dr2=v }
        }
        o=gsub(/\{/,"{",line); c=gsub(/\}/,"}",line); depth+=o-c
        if (ins && depth<=sd) {
          if (dr=="") dr=dr2
          if (sn=="_") sn=""
          if (dr!="") print dr "\t" (sn==""?"-":sn) "\tnginx"
          ins=0
        }
      }' "$f"
  done
}
docroots_lighttpd() {
  find -L "$@" -type f 2>/dev/null | while read -r f; do
    awk '{ l=$0; sub(/#.*/,"",l)
           if (tolower(l) ~ /server\.document-root[ \t]*=/) { v=l; sub(/.*=[ \t]*/,"",v); gsub(/["\047 \t]/,"",v); if (v!="") print v "\t-\tlighttpd" } }' "$f"
  done
}

DOCROOT_FILE="$OUT/docroot_rilevate.tsv"; : > "$DOCROOT_FILE"
WEB_FOUND=""

note "--- Processi web/applicativi in esecuzione (utente, PID, comando)"
ps -eo user:16,pid,comm --no-headers 2>/dev/null | awk '$3 ~ /^(httpd|apache2|nginx|lighttpd|node|nodejs|java|php-fpm.*)$/' >> "$CUR"

# ------------------------------------------------------------ APACHE HTTPD ----
APB=""; for b in apache2ctl apachectl httpd apache2; do have $b && APB="$b" && break; done
APD=""; for d in /etc/apache2 /etc/httpd /usr/local/apache2/conf; do [ -d "$d" ] && APD="$APD $d"; done
note ""; note "################ APACHE HTTPD"
if [ -n "$APB" ]; then
  WEB_FOUND="$WEB_FOUND apache"
  run "$APB -v"
  run "$APB -V 2>&1 | grep -E 'Server version|MPM|Server built|SERVER_CONFIG_FILE|HTTPD_ROOT'"
  run "$APB -M 2>&1 | sort"
  run "$APB -S 2>&1 | head -60"
  AVER="$($APB -v 2>/dev/null | head -1)"; flag INFO "Apache: $AVER"
  APCONF="/etc/apache2 /etc/httpd /usr/local/apache2/conf"
  run "grep -rhiE '^[[:space:]]*(ServerTokens|ServerSignature|TraceEnable|SSLProtocol|SSLCipherSuite|SSLHonorCipherOrder|Header (always )?(set|append|add)|Options |AllowOverride|LimitRequestBody|Timeout|KeepAlive |SSLUseStapling|FileETag|HostnameLookups|ErrorLog|CustomLog|SecRuleEngine|Protocols)' $APCONF 2>/dev/null | sed 's/^[[:space:]]*//' | sort | uniq -c | sort -rn | head -80"
  run "grep -rhiE '^[[:space:]]*(DocumentRoot|ServerName|ServerAlias|<VirtualHost|SSLCertificateFile|Include)' $APCONF 2>/dev/null | sed 's/^[[:space:]]*//' | head -80"
  run "ls -la /etc/apache2/sites-enabled /etc/httpd/conf.d 2>&1"
  grep -rqiE '^[[:space:]]*ServerTokens[[:space:]]+(Prod|ProductOnly)' $APCONF 2>/dev/null || flag WARN "Apache: ServerTokens non impostato a Prod (information disclosure)"
  grep -rqiE '^[[:space:]]*TraceEnable[[:space:]]+Off' $APCONF 2>/dev/null || flag WARN "Apache: TraceEnable Off non trovato"
  grep -rqiE '^[[:space:]]*Header .*(Strict-Transport-Security)' $APCONF 2>/dev/null || flag WARN "Apache: header HSTS non trovato"
  grep -rqiE 'Content-Security-Policy' $APCONF 2>/dev/null || flag WARN "Apache: header Content-Security-Policy non trovato (critico con AngularJS)"
  grep -rqiE 'SSLProtocol.*(\+?TLSv1(\.0|\.1)?[[:space:]]|SSLv3|all[[:space:]]*$)' $APCONF 2>/dev/null && flag WARN "Apache: verificare SSLProtocol (possibili protocolli obsoleti abilitati)"
  $APB -M 2>/dev/null | grep -qiE 'security2|evasive' && flag OK "Apache: mod_security/mod_evasive caricato" || flag INFO "Apache: nessun WAF (mod_security) caricato"
  $APB -M 2>/dev/null | grep -qiE 'autoindex' && flag INFO "Apache: mod_autoindex caricato (verifica 'Options -Indexes')"
  run "ps -eo user,comm | grep -E 'apache|httpd' | sort -u"
else
  echo "Apache non rilevato (binario non nel PATH)" >> "$CUR"; flag INFO "Apache non rilevato"
fi
[ -n "$APD" ] && docroots_apache $APD >> "$DOCROOT_FILE"      # anche senza binario: la configurazione puo' esistere

# ------------------------------------------------------------------- NGINX ----
NGB=""; have nginx && NGB="nginx"
NGCONF=""; for d in /etc/nginx /usr/local/nginx/conf /usr/local/etc/nginx /opt/nginx/conf; do [ -d "$d" ] && NGCONF="$NGCONF $d"; done
if [ -n "$NGB" ] || [ -n "$NGCONF" ] || pgrep -x nginx >/dev/null 2>&1; then
  WEB_FOUND="$WEB_FOUND nginx"
  note ""; note "################ NGINX"
  if [ -n "$NGB" ]; then
    run "$NGB -v 2>&1"
    run "$NGB -V 2>&1 | head -4"
    run "$NGB -V 2>&1 | tr ' ' '\n' | grep -E '^--(with-http_[a-z0-9_]+|add-(dynamic-)?module=.*|user=.*|conf-path=.*|prefix=.*)' | head -50"
    NGVER="$($NGB -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    flag INFO "Nginx: versione ${NGVER:-n/d}"
    flag TODO "Nginx ${NGVER:-}: verificare supporto e CVE su https://nginx.org/en/security_advisories.html"
  else
    note "Binario nginx non nel PATH: versione non rilevata (configurazione in:$NGCONF)"
  fi
  # NB: non si usa 'nginx -T/-t' per mantenere lo script in sola lettura (nginx -t puo' creare directory temporanee/log)
  run "rpm -q nginx 2>/dev/null; dpkg -l 'nginx*' 2>/dev/null | awk '/^ii/{print \$2,\$3}'"
  run "ps -eo user:16,pid,args | grep -E '[n]ginx: (master|worker)' | head -8"
  ps -eo user:16,args 2>/dev/null | grep -E '[n]ginx: worker' | awk '{print $1}' | sort -u | grep -qx root && flag FAIL "Nginx: processi worker eseguiti come root"
  run "ls -la $NGCONF 2>&1 | head -40"
  note "--- Server block: listen / server_name / root"
  cgrep '^[[:space:]]*(listen|server_name|root)[[:space:]]' $NGCONF | sed -E 's/^[[:space:]]+//' | sort -u | head -80 >> "$CUR"
  note "--- Direttive di sicurezza (occorrenze)"
  cgrep_sum '^[[:space:]]*(user|server_tokens|ssl_protocols|ssl_ciphers|ssl_prefer_server_ciphers|ssl_session_tickets|ssl_stapling|ssl_dhparam|add_header|more_set_headers|autoindex|client_max_body_size|limit_req|limit_conn|fastcgi_pass|proxy_pass|uwsgi_pass|auth_basic|access_log|error_log)[[:space:]]' $NGCONF >> "$CUR"
  cgrep '^[[:space:]]*server_tokens[[:space:]]+off' $NGCONF | grep -q . || flag WARN "Nginx: 'server_tokens off' non trovato (information disclosure)"
  cgrep '^[[:space:]]*ssl_protocols' $NGCONF | grep -qiE 'SSLv[23]|TLSv1(\.0|\.1)?([[:space:];]|$)' && flag WARN "Nginx: ssl_protocols include protocolli obsoleti (SSLv3/TLSv1.0/TLSv1.1)"
  cgrep 'Strict-Transport-Security' $NGCONF | grep -q . || flag WARN "Nginx: header HSTS non trovato"
  cgrep 'Content-Security-Policy' $NGCONF | grep -q . || flag WARN "Nginx: header Content-Security-Policy non trovato (critico con AngularJS)"
  cgrep 'X-Content-Type-Options|X-Frame-Options' $NGCONF | grep -q . || flag WARN "Nginx: header X-Content-Type-Options / X-Frame-Options non trovati"
  cgrep '^[[:space:]]*autoindex[[:space:]]+on' $NGCONF | grep -q . && flag WARN "Nginx: autoindex on (directory listing attivo)"
  note "--- fastcgi_pass / proxy_pass (destinazioni)"
  cgrep '(fastcgi|proxy|uwsgi)_pass[[:space:]]' $NGCONF | grep -oE '(fastcgi|proxy|uwsgi)_pass[[:space:]]+[^;]+' | sort | uniq -c >> "$CUR"
  cgrep 'fastcgi_pass[[:space:]]' $NGCONF | grep -oE 'fastcgi_pass[[:space:]]+[^;]+' | grep -vE 'unix:|127\.0\.0\.1|localhost|\[::1\]' | grep -q . && flag WARN "Nginx: fastcgi_pass verso upstream/host non locale (verificare cifratura del traffico FastCGI)"
  cgrep 'fastcgi_pass[[:space:]]' $NGCONF | grep -q . && flag INFO "Nginx: usa FastCGI (PHP-FPM / SimpleSAMLphp)"
  find -L $NGCONF -type f -perm -0002 2>/dev/null | grep -q . && flag FAIL "Nginx: file di configurazione world-writable"
  docroots_nginx $NGCONF >> "$DOCROOT_FILE"
fi

# --------------------------------------------------------------- LIGHTTPD -----
LTB=""; have lighttpd && LTB="lighttpd"
LTCONF=""; [ -d /etc/lighttpd ] && LTCONF="/etc/lighttpd"
if [ -n "$LTB" ] || [ -n "$LTCONF" ] || pgrep -x lighttpd >/dev/null 2>&1; then
  WEB_FOUND="$WEB_FOUND lighttpd"
  note ""; note "################ LIGHTTPD"
  if [ -n "$LTB" ]; then
    run "$LTB -v 2>&1 | head -2"
    flag INFO "Lighttpd: $($LTB -v 2>&1 | head -1)"
  fi
  flag TODO "Lighttpd: verificare supporto e CVE (progetto a ritmo di rilascio ridotto) su https://www.lighttpd.net/security/"
  run "rpm -q lighttpd 2>/dev/null; dpkg -l 'lighttpd*' 2>/dev/null | awk '/^ii/{print \$2,\$3}'"
  run "ls -laR $LTCONF 2>&1 | head -60"
  note "--- Direttive principali (occorrenze)"
  cgrep_sum '^[[:space:]]*(server\.(tag|port|bind|username|groupname|document-root|errorlog|modules|max-request-size|max-connections)|ssl\.[a-z.-]+|dir-listing\.activate|accesslog\.filename|fastcgi\.server|proxy\.server|url\.access-deny|setenv\.add-response-header)[[:space:]]*[=+]' $LTCONF >> "$CUR"
  cgrep '^[[:space:]]*server\.tag' $LTCONF | grep -q . || flag WARN "Lighttpd: server.tag non impostato (il banner espone la versione)"
  cgrep '^[[:space:]]*dir-listing\.activate[[:space:]]*=[[:space:]]*"enable"' $LTCONF | grep -q . && flag WARN "Lighttpd: dir-listing attivo (directory listing)"
  cgrep '^[[:space:]]*ssl\.use-sslv[23][[:space:]]*=[[:space:]]*"enable"' $LTCONF | grep -q . && flag FAIL "Lighttpd: SSLv2/SSLv3 abilitato"
  cgrep '^[[:space:]]*ssl\.(pemfile|engine)' $LTCONF | grep -q . || flag INFO "Lighttpd: nessuna configurazione TLS trovata (HTTP in chiaro o TLS su proxy)"
  cgrep 'Strict-Transport-Security' $LTCONF | grep -q . || flag WARN "Lighttpd: header HSTS non trovato"
  cgrep '^[[:space:]]*server\.username[[:space:]]*=[[:space:]]*"root"' $LTCONF | grep -q . && flag FAIL "Lighttpd: server.username = root"
  cgrep '^[[:space:]]*fastcgi\.server' $LTCONF | grep -q . && flag INFO "Lighttpd: usa FastCGI (PHP-FPM / SimpleSAMLphp)"
  [ -n "$LTCONF" ] && find -L $LTCONF -type f -perm -0002 2>/dev/null | grep -q . && flag FAIL "Lighttpd: file di configurazione world-writable"
  [ -n "$LTCONF" ] && docroots_lighttpd $LTCONF >> "$DOCROOT_FILE"
fi

# ----------------------------------------------------------------- TOMCAT -----
TC_LIST=""   # elementi "home|base|pid"
for pid in $(pgrep -f 'org\.apache\.catalina\.startup\.Bootstrap' 2>/dev/null); do
  cl="$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null)"
  h="$(printf '%s' "$cl" | grep -oE -- '-Dcatalina\.home=[^ ]+' | head -1 | cut -d= -f2)"
  b="$(printf '%s' "$cl" | grep -oE -- '-Dcatalina\.base=[^ ]+' | head -1 | cut -d= -f2)"
  [ -n "$h" ] || h="$b"; [ -n "$b" ] || b="$h"
  [ -n "$h" ] && TC_LIST="$TC_LIST $h|$b|$pid"
done
for d in /opt/tomcat* /opt/apache-tomcat* /usr/share/tomcat* /usr/local/tomcat* /usr/local/apache-tomcat* /var/lib/tomcat* /srv/tomcat*; do
  [ -d "$d/conf" ] || continue
  case "$TC_LIST" in *"$d|"*) ;; *) TC_LIST="$TC_LIST $d|$d|" ;; esac
done
if [ -n "$TC_LIST" ]; then
  WEB_FOUND="$WEB_FOUND tomcat"
  note ""; note "################ APACHE TOMCAT"
  TC_SEEN=" "
  for entry in $TC_LIST; do
    h="${entry%%|*}"; rest="${entry#*|}"; b="${rest%%|*}"; pid="${rest#*|}"
    case "$TC_SEEN" in *" $b "*) continue ;; esac; TC_SEEN="$TC_SEEN$b "
    conf="$b/conf"; [ -d "$conf" ] || conf="$h/conf"
    note ""; note "== CATALINA_HOME=$h  CATALINA_BASE=$b  PID=${pid:-non in esecuzione}"

    # --- versione (3 fonti in ordine) ---
    TCV=""
    [ -x "$h/bin/version.sh" ] && TCV="$(timeout 20 "$h/bin/version.sh" 2>/dev/null | grep -m1 -i 'Server number' | awk -F: '{gsub(/[ \t]/,"",$2); print $2}')"
    [ -z "$TCV" ] && have unzip && [ -r "$h/lib/catalina.jar" ] && TCV="$(unzip -p "$h/lib/catalina.jar" org/apache/catalina/util/ServerInfo.properties 2>/dev/null | grep -m1 '^server.number' | cut -d= -f2)"
    [ -z "$TCV" ] && [ -r "$h/RELEASE-NOTES" ] && TCV="$(grep -m1 -oE 'Apache Tomcat Version [0-9.]+' "$h/RELEASE-NOTES" | grep -oE '[0-9][0-9.]*')"
    [ -z "$TCV" ] && TCV="$(rpm -q tomcat --qf '%{VERSION}' 2>/dev/null | grep -E '^[0-9]')"
    note "Versione Tomcat: ${TCV:-non determinata}"
    TCM="${TCV%%.*}"
    if [ -z "$TCV" ]; then
      flag WARN "Tomcat ($b): versione non determinabile"
    else
      flag INFO "Tomcat: versione $TCV in $b"
      case "$TCM" in
        ''|*[!0-9]*) ;;
        *) if [ "$TCM" -le 8 ]; then flag FAIL "Tomcat $TCV: ramo $TCM.x fuori supporto (7.x e 8.5.x terminati): migrare a una versione supportata"
           else flag TODO "Tomcat $TCV: verificare supporto e CVE su https://tomcat.apache.org/whichversion.html e https://tomcat.apache.org/security.html"; fi ;;
      esac
    fi

    # --- processo, utente, JVM, porte ---
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
      u="$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')"
      note "Utente processo: $u"
      [ "$u" = "root" ] && flag FAIL "Tomcat ($b): eseguito come root"
      jb="$(readlink -f /proc/$pid/exe 2>/dev/null)"
      [ -n "$jb" ] && { note "JVM: $jb"; "$jb" -version 2>&1 | head -3 >> "$CUR"; }
      note "Porte in ascolto del processo:"
      ss -H -tlnp 2>/dev/null | grep "pid=$pid," | awk '{print "  " $4}' >> "$CUR"
    fi

    # --- server.xml (commenti rimossi, segreti oscurati) ---
    SX="$conf/server.xml"
    if [ -r "$SX" ]; then
      SXC="$(xml_nocomments "$SX")"
      note "--- Connector (attributi sensibili oscurati)"
      CONNS="$(printf '%s' "$SXC" | tr '\n' ' ' | grep -oE '<Connector[^>]*>')"
      printf '%s\n' "$CONNS" | sed -E 's/[[:space:]]+/ /g' | redact_xml >> "$CUR"
      if printf '%s\n' "$CONNS" | grep -qi 'AJP'; then
        flag WARN "Tomcat ($b): connettore AJP abilitato (storico CVE-2020-1938 'Ghostcat'): verificare secret, address e versione"
        printf '%s\n' "$CONNS" | grep -i 'AJP' | grep -qi 'secretRequired="false"' && flag FAIL "Tomcat ($b): AJP con secretRequired=false"
      fi
      printf '%s' "$SXC" | grep -oE 'protocols="[^"]*"|sslProtocol="[^"]*"|ciphers="[^"]*"' | sort -u | sed 's/^/  /' >> "$CUR"
      printf '%s' "$SXC" | grep -oE 'protocols="[^"]*"|sslProtocol="[^"]*"' | grep -qiE 'SSLv[23]|TLSv1(\.0|\.1)?([^0-9.]|$)' && flag WARN "Tomcat ($b): protocolli TLS obsoleti abilitati (SSLv3/TLSv1.0/TLSv1.1)"
      printf '%s' "$SXC" | grep -qE '<Server[^>]*shutdown="SHUTDOWN"' && flag WARN "Tomcat ($b): comando di shutdown di default ('SHUTDOWN') sulla porta di controllo"
      printf '%s' "$SXC" | grep -qiE 'showServerInfo="false"' || flag WARN "Tomcat ($b): ErrorReportValve showServerInfo=\"false\" non trovato (information disclosure)"
      printf '%s' "$SXC" | grep -q 'AccessLogValve' || flag WARN "Tomcat ($b): AccessLogValve non configurata (nessun access log)"
      SXP="$(stat -c %a "$SX" 2>/dev/null)"
      [ -n "$SXP" ] && [ $(( 8#$SXP & 4 )) -ne 0 ] && flag WARN "Tomcat ($b): server.xml leggibile da tutti (permessi $SXP)"
    else
      note "server.xml non leggibile: $SX"
    fi

    # --- utenti di amministrazione ---
    TU="$conf/tomcat-users.xml"
    if [ -r "$TU" ]; then
      TUC="$(xml_nocomments "$TU")"
      note "--- tomcat-users.xml (password oscurate)"
      printf '%s\n' "$TUC" | grep -E '<(user|role)[ />]' | redact_xml >> "$CUR"
      NUSR="$(printf '%s\n' "$TUC" | grep -cE '<user[ ]')"
      if [ "${NUSR:-0}" -gt 0 ]; then
        printf '%s' "${SXC:-}" | grep -q 'CredentialHandler' || flag WARN "Tomcat ($b): $NUSR utenti in tomcat-users.xml senza CredentialHandler (password in chiaro)"
        printf '%s\n' "$TUC" | grep -E '<user ' | grep -qiE 'manager-(gui|script|jmx|status)|admin-(gui|script)' && flag WARN "Tomcat ($b): utenti con ruoli manager/admin definiti"
      fi
      TUP="$(stat -c %a "$TU" 2>/dev/null)"
      [ -n "$TUP" ] && [ $(( 8#$TUP & 4 )) -ne 0 ] && flag WARN "Tomcat ($b): tomcat-users.xml leggibile da tutti (permessi $TUP)"
    fi

    # --- webapps e inventario librerie JAR (supply chain) ---
    if [ -d "$b/webapps" ]; then
      note "--- webapps"
      ls -la "$b/webapps" >> "$CUR" 2>&1
      for a in manager host-manager; do [ -d "$b/webapps/$a" ] && flag WARN "Tomcat ($b): webapp '$a' presente: limitare l'accesso per IP/rete o rimuoverla"; done
      for a in examples docs; do [ -d "$b/webapps/$a" ] && flag WARN "Tomcat ($b): webapp '$a' (esempi/documentazione) presente: rimuoverla"; done
    fi
    JARS="$(find "$b/webapps" "$h/lib" -maxdepth 5 -name '*.jar' 2>/dev/null | sed 's|.*/||' | sort -u)"
    JARF="$OUT/09_tomcat_jar_$(basename "$b").txt"
    printf '%s\n' "$JARS" > "$JARF"
    note "Inventario librerie JAR: $(printf '%s\n' "$JARS" | grep -c .) file distinti in $(basename "$JARF")"
    printf '%s\n' "$JARS" | grep -qE '^log4j-core-2\.([0-9]|1[0-6])\.' && flag FAIL "Tomcat ($b): log4j-core 2.0-2.16 (Log4Shell e CVE successive): aggiornare"
    printf '%s\n' "$JARS" | grep -qE '^log4j-1\.' && flag WARN "Tomcat ($b): log4j 1.x (fuori supporto) presente"
    printf '%s\n' "$JARS" | grep -qiE '^struts2?-core' && flag WARN "Tomcat ($b): Apache Struts presente: verificare versione e CVE"
  done
fi

# ---------------------------------------------------------------- NODE.JS -----
NODEB=""; for b in node nodejs; do have $b && NODEB="$b" && break; done
NPIDS="$( { pgrep -x node 2>/dev/null; pgrep -x nodejs 2>/dev/null; } | sort -u | head -10 | tr '\n' ' ')"
if [ -n "$NODEB" ] || [ -n "$NPIDS" ]; then
  WEB_FOUND="$WEB_FOUND node"
  note ""; note "################ NODE.JS"
  if [ -n "$NODEB" ]; then
    NV="$($NODEB -v 2>/dev/null | tr -d 'v')"
    note "Node.js: v${NV:-n/d}  ($(command -v $NODEB))"
    flag INFO "Node.js: versione ${NV:-n/d}"
    NM="${NV%%.*}"
    case "$NM" in
      ''|*[!0-9]*) ;;
      *) [ "$NM" -le 20 ] && flag FAIL "Node.js $NV: release fuori supporto (regola statica dello script: verificare su https://endoflife.date/nodejs)"
         [ $((NM % 2)) -eq 1 ] && flag WARN "Node.js $NV: release dispari, non LTS (non adatta alla produzione)" ;;
    esac
  fi
  note "Moduli globali:"; ls /usr/lib/node_modules /usr/local/lib/node_modules 2>/dev/null >> "$CUR"
  for pid in $NPIDS; do
    [ -d "/proc/$pid" ] || continue
    u="$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')"
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)"
    args="$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null | redact_args)"
    ports="$(ss -H -tlnp 2>/dev/null | grep "pid=$pid," | awk '{print $4}' | tr '\n' ' ')"
    note ""; note "== PID $pid  utente=$u  cwd=${cwd:-n/d}"
    note "   comando : $args"
    note "   porte   : ${ports:-nessuna}"
    [ "$u" = "root" ] && flag FAIL "Node.js (PID $pid, $cwd): processo eseguito come root"
    for p in $ports; do
      case "$p" in
        127.0.0.1:*|\[::1\]:*) ;;
        *:80|*:443) ;;
        *) flag WARN "Node.js (PID $pid): in ascolto su $p, non solo locale: preferire bind su 127.0.0.1 dietro reverse proxy" ;;
      esac
    done
    if [ -n "$cwd" ] && [ -r "$cwd/package.json" ] && [ -n "$NODEB" ]; then
      note "   package.json (dipendenze dirette):"
      timeout 10 "$NODEB" -e 'try{var p=require(process.argv[1]);console.log("   "+(p.name||"?")+"@"+(p.version||"?"));var d=p.dependencies||{};Object.keys(d).sort().forEach(function(k){console.log("     "+k+" "+d[k])})}catch(e){console.log("   package.json non leggibile: "+e.message)}' "$cwd/package.json" >> "$CUR" 2>&1
      { [ -f "$cwd/package-lock.json" ] || [ -f "$cwd/yarn.lock" ] || [ -f "$cwd/pnpm-lock.yaml" ]; } || flag WARN "Node.js ($cwd): nessun lockfile (versioni delle dipendenze non riproducibili)"
      note "   Per le CVE sulle dipendenze: eseguire 'npm audit' su una COPIA del progetto (richiede rete)"
    fi
    if [ -n "$cwd" ] && [ -f "$cwd/.env" ]; then
      EP="$(stat -c %a "$cwd/.env" 2>/dev/null)"
      flag WARN "Node.js ($cwd): file .env presente (permessi $EP): verificare che non sia leggibile da altri e non servito via web"
    fi
  done
fi

flag INFO "Web/application server rilevati: ${WEB_FOUND:- nessuno}"
sort -u -o "$DOCROOT_FILE" "$DOCROOT_FILE"
note ""; note "--- DocumentRoot rilevati (percorso / servername / server)"; cat "$DOCROOT_FILE" >> "$CUR"

# ===================================================== 10 PHP ================
sec 10_php.txt "PHP"
if have php; then
  run "php -v"
  run "php -m"
  run "php --ini"
  PHPV="$(php -r 'echo PHP_VERSION;' 2>/dev/null)"
  flag INFO "PHP CLI: $PHPV  (verificare EOL su https://endoflife.date/php)"
  PHPMM="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)"
  case "$PHPMM" in
    5.*|7.*|8.0|8.1) flag FAIL "PHP $PHPMM fuori supporto di sicurezza (EOL): upgrade necessario" ;;
  esac
fi
run "ls -d /etc/php* /etc/php.d /etc/php.ini 2>/dev/null; find /etc -name php.ini 2>/dev/null"
KEYS='expose_php|display_errors|display_startup_errors|log_errors|error_log|allow_url_fopen|allow_url_include|disable_functions|open_basedir|session\.(cookie_httponly|cookie_secure|cookie_samesite|use_strict_mode|use_only_cookies|gc_maxlifetime|name|save_path|cookie_lifetime|sid_length|use_trans_sid)|file_uploads|upload_max_filesize|post_max_size|max_execution_time|memory_limit|register_globals|magic_quotes_gpc|short_open_tag|enable_dl|zend\.assertions|default_charset|date\.timezone|opcache\.enable'
for ini in $(find /etc -name php.ini 2>/dev/null); do
  run "echo '### $ini'; grep -E '^[[:space:]]*($KEYS)[[:space:]]*=' '$ini'"
  grep -qE '^[[:space:]]*display_errors[[:space:]]*=[[:space:]]*(On|1|true)' "$ini" && flag FAIL "PHP ($ini): display_errors attivo"
  grep -qE '^[[:space:]]*expose_php[[:space:]]*=[[:space:]]*(On|1)' "$ini" && flag WARN "PHP ($ini): expose_php attivo"
  grep -qE '^[[:space:]]*session\.cookie_httponly[[:space:]]*=[[:space:]]*(1|On|true)' "$ini" || flag WARN "PHP ($ini): session.cookie_httponly non attivo"
  grep -qE '^[[:space:]]*session\.cookie_secure[[:space:]]*=[[:space:]]*(1|On|true)' "$ini" || flag WARN "PHP ($ini): session.cookie_secure non attivo"
  grep -qE '^[[:space:]]*disable_functions[[:space:]]*=[[:space:]]*[a-z]' "$ini" || flag WARN "PHP ($ini): disable_functions vuoto"
  grep -qE '^[[:space:]]*allow_url_include[[:space:]]*=[[:space:]]*(On|1)' "$ini" && flag FAIL "PHP ($ini): allow_url_include attivo"
done
run "dpkg -l 'php*' 2>/dev/null | awk '/^ii/{print \$2,\$3}'; rpm -qa 'php*' 2>/dev/null"
run "ls /etc/php/*/fpm/pool.d/ 2>/dev/null; grep -rhE '^(user|group|listen|pm\.|php_admin_(value|flag))' /etc/php/*/fpm/pool.d/ /etc/php-fpm.d/ 2>/dev/null | head -40"

# ================================================== 11 MARIADB ===============
sec 11_mariadb.txt "MARIADB / MYSQL"
DBC=""; for c in mariadb mysql; do have $c && DBC="$c" && break; done
# Server DB LOCALE in esecuzione? Se no (DB su altra macchina) le query vengono saltate automaticamente,
# cosi' il client non si collega mai a host remoti eventualmente indicati in ~/.my.cnf
LOCALDB=0
{ pgrep -x mariadbd >/dev/null 2>&1 || pgrep -x mysqld >/dev/null 2>&1 || pgrep -x mariadbd-safe >/dev/null 2>&1; } && LOCALDB=1
if [ "$SKIP_DB" -eq 1 ]; then
  echo "Accesso al database saltato (-D)" >> "$CUR"; flag INFO "MariaDB: raccolta DB saltata su richiesta (-D)"
elif [ -n "$DBC" ]; then
  run "$DBC --version"
  flag INFO "DB client: $($DBC --version 2>/dev/null | head -1)"
  run "systemctl is-active mariadb mysql mysqld 2>&1"
  run "ls -d /etc/mysql /etc/my.cnf /etc/my.cnf.d 2>/dev/null"
  runr "grep -rhvE '^[[:space:]]*(#|;|$)' /etc/my.cnf /etc/my.cnf.d/ /etc/mysql/ 2>/dev/null"
  run "ls -la /var/lib/mysql 2>&1 | head -5; ls -la /var/log/mysql /var/log/mariadb 2>&1 | head"
  grep -rhE '^[[:space:]]*bind-address' /etc/my.cnf /etc/my.cnf.d/ /etc/mysql/ 2>/dev/null | grep -qE '0\.0\.0\.0|::' && flag FAIL "MariaDB: bind-address aperto a tutte le interfacce"
  grep -rhEq '^[[:space:]]*local[-_]infile[[:space:]]*=[[:space:]]*(1|ON)' /etc/my.cnf /etc/my.cnf.d/ /etc/mysql/ 2>/dev/null && flag WARN "MariaDB: local_infile attivo"
  grep -rhEq '^[[:space:]]*ssl' /etc/my.cnf /etc/my.cnf.d/ /etc/mysql/ 2>/dev/null || flag WARN "MariaDB: nessuna configurazione TLS trovata nei file"
  # Query solo lettura via socket (root/unix_socket). Nessun hash di password viene estratto.
  Q() { timeout 15 $DBC --connect-timeout=5 -N -B -e "$1" 2>&1; }
  if [ "$LOCALDB" -eq 1 ] && [ "$IS_ROOT" -eq 1 ] && Q "SELECT 1" >/dev/null 2>&1; then
    flag INFO "MariaDB: connessione via socket riuscita, raccolgo audit utenti/variabili"
    run "$DBC --connect-timeout=5 -e 'SELECT VERSION() AS version\\G' 2>&1"
    run "$DBC --connect-timeout=5 -e \"SELECT user,host,plugin,is_role,password_expired,account_locked FROM mysql.global_priv LIMIT 0\" 2>&1 | head -1"
    run "$DBC --connect-timeout=5 -e \"SELECT User,Host,plugin,password_expired,account_locked,JSON_VALUE(Priv,'\$.authentication_string')<>'' AS has_password FROM mysql.global_priv ORDER BY User,Host\" 2>&1 || $DBC --connect-timeout=5 -e \"SELECT User,Host,plugin,(authentication_string<>'') AS has_password FROM mysql.user\" 2>&1"
    run "$DBC --connect-timeout=5 -e \"SELECT user,host FROM mysql.user WHERE host IN ('%','') OR user=''\" 2>&1"
    run "$DBC --connect-timeout=5 -e \"SELECT grantee,table_schema,privilege_type FROM information_schema.schema_privileges ORDER BY grantee\" 2>&1 | head -150"
    run "$DBC --connect-timeout=5 -e \"SELECT grantee,privilege_type FROM information_schema.user_privileges WHERE privilege_type IN ('ALL PRIVILEGES','SUPER','FILE','GRANT OPTION','PROCESS','SHUTDOWN') OR grantee LIKE '%root%'\" 2>&1"
    run "$DBC --connect-timeout=5 -e \"SHOW GLOBAL VARIABLES WHERE Variable_name IN ('version','version_comment','have_ssl','require_secure_transport','tls_version','ssl_cipher','local_infile','secure_file_priv','skip_networking','bind_address','log_error','general_log','slow_query_log','log_bin','expire_logs_days','binlog_expire_logs_seconds','default_password_lifetime','validate_password','simple_password_check_minimum_length','sql_mode','max_connect_errors','skip_name_resolve','server_audit_logging','server_audit_events','server_audit_file_path','innodb_encrypt_tables','encrypt_binlog','aria_encrypt_tables')\" 2>&1"
    run "$DBC --connect-timeout=5 -e \"SELECT plugin_name,plugin_status FROM information_schema.plugins WHERE plugin_name RLIKE 'audit|password|encrypt|simple_password|cracklib|ed25519|pam|ssl' \" 2>&1"
    run "$DBC --connect-timeout=5 -e \"SELECT table_schema, ROUND(SUM(data_length+index_length)/1024/1024,1) AS MB, COUNT(*) AS tabelle FROM information_schema.tables WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys') GROUP BY table_schema\" 2>&1"
    run "$DBC --connect-timeout=5 -e \"SELECT table_schema,table_name,engine FROM information_schema.tables WHERE engine='MyISAM' AND table_schema NOT IN ('mysql','information_schema','performance_schema','sys') LIMIT 50\" 2>&1"
    NOPW=$(Q "SELECT COUNT(*) FROM mysql.user WHERE (authentication_string='' OR authentication_string IS NULL) AND plugin NOT IN ('unix_socket','auth_socket','mysql_no_login') AND user<>''" | tail -1)
    [ "${NOPW:-0}" -gt 0 ] 2>/dev/null && flag FAIL "MariaDB: $NOPW utenti senza password (esclusi unix_socket)"
    WILD=$(Q "SELECT COUNT(*) FROM mysql.user WHERE host='%'" | tail -1)
    [ "${WILD:-0}" -gt 0 ] 2>/dev/null && flag WARN "MariaDB: $WILD utenti con host '%'"
    Q "SHOW GLOBAL VARIABLES LIKE 'require_secure_transport'" | grep -qi 'ON' || flag WARN "MariaDB: require_secure_transport non attivo"
    Q "SELECT plugin_name FROM information_schema.plugins WHERE plugin_name='SERVER_AUDIT' AND plugin_status='ACTIVE'" | grep -qi audit && flag OK "MariaDB: server_audit attivo" || flag WARN "MariaDB: audit plugin (server_audit) non attivo"
  else
    if [ "$LOCALDB" -eq 0 ]; then
      echo "Nessun server MariaDB/MySQL locale in esecuzione (DB remoto): nessuna query eseguita. Eseguire lo script anche sul server DB." >> "$CUR"
      flag INFO "MariaDB: server DB non locale, query saltate (eseguire lo script sul server DB)"
    else
      echo "Connessione al DB non riuscita via socket (serve root con unix_socket). Eseguire manualmente gli audit utenti/grant." >> "$CUR"
      flag INFO "MariaDB: audit utenti/grant NON raccolto (connessione non disponibile)"
    fi
  fi
  flag TODO "Verifica EOL MariaDB su https://endoflife.date/mariadb"
else
  echo "Client MariaDB/MySQL non rilevato" >> "$CUR"
fi

# ============================ 12 APPLICATIVI WEB: librerie e permessi ========
sec 12_applicativi_web.txt "WEB ROOT: LIBRERIE FRONTEND, PERMESSI, FILE A RISCHIO (solo nomi, nessun contenuto)"
EXISTING=""; for d in $WEBROOTS; do [ -d "$d" ] && EXISTING="$EXISTING $d"; done
# aggiunge i DocumentRoot rilevati nella sezione 09 (Apache/Nginx/Lighttpd) se non gia' coperti
if [ -s "$DOCROOT_FILE" ]; then
  while IFS=$'\t' read -r dr sn typ; do
    case "$dr" in ''|*'$'*) continue ;; esac
    [ -d "$dr" ] || continue
    covered=0; for e in $EXISTING; do case "$dr/" in "$e"/*) covered=1 ;; esac; done
    [ "$covered" -eq 0 ] && EXISTING="$EXISTING $dr"
  done < "$DOCROOT_FILE"
fi
echo "Web root analizzate:${EXISTING:- nessuna}" >> "$CUR"
if [ -n "$EXISTING" ]; then
  run "find $EXISTING -maxdepth 2 -mindepth 1 -type d 2>/dev/null | head -50"
  # Librerie JS e versioni (intestazione del file)
  run "find $EXISTING -type f \\( -iname 'angular*.js' -o -iname 'jquery*.js' -o -iname 'bootstrap*.js' -o -iname 'lodash*.js' -o -iname 'moment*.js' -o -iname 'tinymce*.js' -o -iname 'ckeditor*.js' \\) -not -path '*/node_modules/*' 2>/dev/null | while read f; do v=\$(head -c 600 \"\$f\" | grep -oiE '(v|version)[ :]*[0-9]+\\.[0-9]+(\\.[0-9]+)?' | head -1); echo \"\$f  -> \${v:-versione non rilevata}\"; done | head -80"
  AJS=$(find $EXISTING -type f -iname 'angular*.js' 2>/dev/null | head -1)
  [ -n "$AJS" ] && flag FAIL "AngularJS 1.x rilevato (EOL dal 12/2021): es. $AJS"
  # Permessi pericolosi
  run "find $EXISTING -type f -perm -0002 2>/dev/null | head -50"
  run "find $EXISTING -type d -perm -0002 2>/dev/null | head -30"
  WW=$(find $EXISTING -type f -perm -0002 2>/dev/null | wc -l)
  [ "$WW" -gt 0 ] && flag FAIL "File world-writable nelle web root: $WW"
  # File sensibili/dimenticati esposti
  run "find $EXISTING \\( -name '.git' -o -name '.svn' -o -name '.env' -o -name '.htpasswd' -o -name 'phpinfo*.php' -o -name 'info.php' -o -name 'test.php' -o -name 'adminer*.php' -o -name 'phpmyadmin' \\) 2>/dev/null | head -50"
  run "find $EXISTING -type f \\( -iname '*.bak' -o -iname '*.old' -o -iname '*.orig' -o -iname '*.sql' -o -iname '*.sql.gz' -o -iname '*.zip' -o -iname '*.tar.gz' -o -iname '*.swp' -o -iname '*~' -o -iname 'config*.php.*' \\) 2>/dev/null | head -60"
  FIND=$(find $EXISTING \( -name '.git' -o -name '.env' -o -name 'phpinfo*.php' -o -name 'info.php' \) 2>/dev/null | wc -l)
  [ "$FIND" -gt 0 ] && flag FAIL "File/dir sensibili nelle web root (.git/.env/phpinfo): $FIND"
  BK=$(find $EXISTING -type f \( -iname '*.bak' -o -iname '*.old' -o -iname '*.sql' -o -iname '*.sql.gz' -o -iname '*.zip' -o -iname '*.tar.gz' \) 2>/dev/null | wc -l)
  [ "$BK" -gt 0 ] && flag WARN "Backup/dump/archivi dentro le web root: $BK"
  # Conteggio file per estensione e proprietà
  run "find $EXISTING -type f -name '*.php' 2>/dev/null | wc -l"
  run "find $EXISTING -type f -name '*.php' -printf '%u:%g %m\n' 2>/dev/null | sort | uniq -c | sort -rn | head"
  # Pattern a rischio: SOLO conteggi per file, nessun contenuto
  run "grep -rIlE 'mysql_(query|connect)\\(' --include=*.php $EXISTING 2>/dev/null | head -30"
  run "grep -rIlE '(eval|assert|system|shell_exec|passthru|exec|popen|proc_open)[[:space:]]*\\(' --include=*.php $EXISTING 2>/dev/null | head -30"
  run "grep -rIlE '(include|require)(_once)?[[:space:]]*\\(?[[:space:]]*\\\$_(GET|POST|REQUEST|COOKIE)' --include=*.php $EXISTING 2>/dev/null | head -30"
  run "grep -rIlE '(md5|sha1)[[:space:]]*\\(' --include=*.php $EXISTING 2>/dev/null | head -30"
  run "grep -rIlE 'unserialize[[:space:]]*\\(' --include=*.php $EXISTING 2>/dev/null | head -30"
  run "grep -rIlE '\\\$_(GET|POST|REQUEST)\\[[^]]+\\][^;]{0,80}(SELECT|INSERT|UPDATE|DELETE)|(SELECT|INSERT|UPDATE|DELETE)[^;]{0,120}\\\$_(GET|POST|REQUEST)' --include=*.php $EXISTING 2>/dev/null | head -50"
  run "grep -rIl 'password_hash' --include=*.php $EXISTING 2>/dev/null | head -10"
  run "grep -rIl 'ng-bind-html\\|\\\$sce\\|trustAsHtml' $EXISTING 2>/dev/null | head -20"
  flag TODO "Elenchi file con pattern a rischio (SQLi, eval, include dinamici, md5/sha1) in 12_applicativi_web.txt: eseguire Semgrep/PHPStan per l'analisi puntuale"
else
  flag INFO "Nessuna web root trovata nei percorsi indicati: usa -w per specificarli"
fi

# =================================================== 13 CERTIFICATI TLS ======
sec 13_certificati_tls.txt "CERTIFICATI TLS (solo scadenze, nessuna chiave privata)"
CERTS="$( {
  grep -rhiE '^[[:space:]]*SSLCertificateFile' /etc/apache2 /etc/httpd 2>/dev/null | awk '{print $2}' | tr -d '"'
  grep -rhE '^[[:space:]]*ssl_certificate[[:space:]]' /etc/nginx /usr/local/nginx/conf /usr/local/etc/nginx 2>/dev/null | awk '{print $2}' | tr -d '";'
  grep -rhE 'ssl\.(pemfile|cert[a-z-]*)[[:space:]]*=' /etc/lighttpd 2>/dev/null | grep -oE '"[^"]+"' | tr -d '"'
  find /etc/letsencrypt/live -name 'cert.pem' 2>/dev/null
  find /etc/pki/tls/certs /etc/ssl/private -maxdepth 1 -name '*.crt' -o -maxdepth 1 -name '*.pem' 2>/dev/null | grep -v 'ca-bundle\|cert.pem$'
} | sort -u)"
if [ -n "$CERTS" ] && have openssl; then
  for c in $CERTS; do
    case "$c" in /*) ;; *) c="/etc/nginx/$c" ;; esac     # percorsi relativi di nginx
    [ -r "$c" ] || continue
    run "echo '### $c'; openssl x509 -in '$c' -noout -subject -issuer -enddate -dates -ext subjectAltName 2>&1 | head -8; openssl x509 -in '$c' -noout -text 2>/dev/null | grep -E 'Signature Algorithm|Public-Key' | head -2"
    openssl x509 -in "$c" -noout -checkend 2592000 >/dev/null 2>&1 || flag WARN "Certificato in scadenza (<30gg) o scaduto: $c"
  done
else
  echo "Nessun certificato locale individuato" >> "$CUR"
fi
run "ls /etc/letsencrypt/renewal 2>/dev/null; systemctl is-active certbot.timer 2>&1"

# ============================================ 14 BACKUP / CONTINUITA' ========
sec 14_backup_continuita.txt "INDIZI DI BACKUP (verificare manualmente test di ripristino)"
for t in rsync borg borgmatic restic duplicity bacula-fd bareos-fd veeam amanda rclone mariabackup mariadb-backup mysqldump; do
  have "$t" && echo "presente: $t" >> "$CUR"
done
runr "grep -rilE 'backup|rsync|borg|restic|mysqldump|mariabackup|dump' /etc/cron* /var/spool/cron 2>/dev/null"
runr "grep -rhiE 'backup|rsync|borg|restic|mysqldump|mariabackup' /etc/cron.d /etc/crontab /var/spool/cron 2>/dev/null | grep -v '^#'"
run "systemctl list-timers --all --no-pager 2>/dev/null | grep -iE 'backup|borg|restic'"
run "ls -la --time-style=long-iso /backup /var/backups /mnt/backup /srv/backup 2>/dev/null | head -30"
grep -rqiE 'backup|rsync|borg|restic|mysqldump|mariabackup' /etc/cron* /var/spool/cron 2>/dev/null && flag INFO "Indizi di job di backup in cron (verificare esistenza di restore test)" || flag WARN "Nessun job di backup rilevato in cron/timer"

# ============================================= 15 CONTAINER / VIRT ===========
sec 15_container.txt "CONTAINER"
# Interroga solo daemon gia' attivi (evita socket activation di docker.socket)
systemctl is-active --quiet docker 2>/dev/null && run "docker ps -a 2>&1 | head -20" || echo "docker non attivo/non installato" >> "$CUR"
have podman && run "podman ps -a 2>&1 | head -20"

# =================================================== 16 SIMPLESAMLPHP ========
sec 16_simplesamlphp.txt "SIMPLESAMLPHP (SSO / SAML): VERSIONE E CONFIGURAZIONE"
SSP_SEARCH="/var /srv /opt /usr/share /usr/local"
# oscura i valori delle chiavi PHP-array sensibili: 'secretsalt' => '...'
redact_php() { sed -E "s/(['\"][^'\"]*(pass|secret|salt|token|key|credential)[^'\"]*['\"][[:space:]]*=>[[:space:]]*).*/\1<REDACTED>/I"; }

# Candidati: directory O symlink il cui nome inizia per "simplesaml" (es. simplesamlphp -> simplesamlphp-1.19.7)
SSP_CANDS="$(find $SSP_SEARCH -maxdepth 5 \( -type d -o -type l \) -iname 'simplesaml*' -not -path '*/vendor/*' -not -path '*/node_modules/*' 2>/dev/null | sort -u)"
SSP_ROOTS=""
for c in $SSP_CANDS; do
  r="$(readlink -f "$c" 2>/dev/null)"; [ -n "$r" ] || continue
  [ "$(basename "$r")" = "www" ] && r="$(dirname "$r")"      # alias web tipo .../simplesaml -> .../www
  if [ -d "$r/www" ] || [ -f "$r/config/config.php" ] || [ -d "$r/modules" ]; then
    if [ -L "$c" ]; then note "SYMLINK  : $c -> $(readlink "$c")   (percorso reale: $r)"
    else note "DIRECTORY: $c"; fi
    case " $SSP_ROOTS " in *" $r "*) ;; *) SSP_ROOTS="$SSP_ROOTS $r" ;; esac
  fi
done

if [ -z "$SSP_ROOTS" ]; then
  note "SimpleSAMLphp non rilevato in: $SSP_SEARCH"
  flag INFO "SimpleSAMLphp non rilevato (cercato in: $SSP_SEARCH)"
else
  NROOT=$(echo $SSP_ROOTS | wc -w)
  [ "$NROOT" -gt 1 ] && flag WARN "SimpleSAMLphp: $NROOT installazioni/versioni presenti ($SSP_ROOTS): rimuovere quelle non in uso"
  for r in $SSP_ROOTS; do
    note ""; note "################ $r"

    # --- Versione: 3 fonti indipendenti, confrontate tra loro
    VNAME="$(basename "$r" | grep -oE '[0-9]+(\.[0-9]+){1,3}' | head -1)"
    VCODE=""
    for f in "$r/src/SimpleSAML/Configuration.php" "$r/lib/SimpleSAML/Configuration.php"; do
      [ -r "$f" ] || continue
      VCODE="$(grep -hoE "VERSION[[:space:]]*=[[:space:]]*['\"][0-9][^'\"]*['\"]" "$f" 2>/dev/null | head -1 | grep -oE "[0-9][^'\"]*")"
      [ -n "$VCODE" ] && break
    done
    VCOMP=""
    [ -r "$r/composer.json" ] && VCOMP="$(grep -m1 -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$r/composer.json" 2>/dev/null | grep -oE '[0-9][^"]*')"
    VER="${VCODE:-${VCOMP:-$VNAME}}"
    note "Versione dal nome directory        : ${VNAME:-n/d}"
    note "Versione dal codice (Configuration): ${VCODE:-n/d}"
    note "Versione da composer.json          : ${VCOMP:-n/d}"
    [ -r "$r/composer.json" ] && note "Requisito PHP (composer.json)    : $(grep -m1 -E '"php"[[:space:]]*:' "$r/composer.json" | tr -s ' ')"

    if [ -z "$VER" ]; then
      flag WARN "SimpleSAMLphp in $r: versione non determinabile, verificare a mano"
    else
      flag INFO "SimpleSAMLphp: versione $VER in $r"
      if [ -n "$VNAME" ] && [ -n "$VCODE" ]; then
        case "$VCODE" in "$VNAME"*) ;; *) flag WARN "SimpleSAMLphp ($r): nome directory ($VNAME) diverso dalla versione nel codice ($VCODE): aggiornamento manuale incompleto?" ;; esac
      fi
      case "${VER%%.*}" in
        1) flag FAIL "SimpleSAMLphp $VER: ramo 1.x fuori supporto (la 1.19 ha ricevuto fix di sicurezza solo fino a fine 2023): migrare alla 2.x" ;;
        2) flag TODO "SimpleSAMLphp $VER: verificare supporto e advisory su https://simplesamlphp.org/security/" ;;
      esac
    fi

    # --- Permessi e configurazione (nessun valore segreto viene salvato)
    run "ls -ld '$r' '$r/config' '$r/metadata' '$r/cert' '$r/log' '$r/data' 2>&1"
    CFG="$r/config/config.php"
    if [ -r "$CFG" ]; then
      CFGC="$(grep -vE '^[[:space:]]*(//|#|\*|/\*)' "$CFG")"      # senza righe commentate
      note "--- config.php (impostazioni principali, segreti oscurati)"
      echo "$CFGC" | grep -E "baseurlpath|session\.|showerrors|errorreporting|'debug'|technicalcontact|admin\.protectindexpage|enable\.|store\.type|logging\.|trusted\.url|language\.default|timezone" | redact_php >> "$CUR"
      echo "$CFGC" | grep -qE "['\"]secretsalt['\"][[:space:]]*=>[[:space:]]*['\"]defaultsecretsalt['\"]" && flag FAIL "SimpleSAMLphp ($r): 'secretsalt' di default"
      echo "$CFGC" | grep -qE "['\"]auth\.adminpassword['\"][[:space:]]*=>[[:space:]]*['\"]123['\"]" && flag FAIL "SimpleSAMLphp ($r): password admin di default ('123')"
      echo "$CFGC" | grep -qE "['\"]showerrors['\"][[:space:]]*=>[[:space:]]*true" && flag WARN "SimpleSAMLphp ($r): showerrors attivo"
      echo "$CFGC" | grep -qE "['\"]session\.cookie\.secure['\"][[:space:]]*=>[[:space:]]*true" || flag WARN "SimpleSAMLphp ($r): session.cookie.secure non impostato a true"
      echo "$CFGC" | grep -qE "['\"]admin\.protectindexpage['\"][[:space:]]*=>[[:space:]]*true" || flag WARN "SimpleSAMLphp ($r): admin.protectindexpage non attivo (verificare)"
      echo "$CFGC" | grep -qE "['\"]technicalcontact_email['\"][[:space:]]*=>[[:space:]]*['\"]na@example\.org['\"]" && flag WARN "SimpleSAMLphp ($r): technicalcontact_email di default"
      CPERM="$(stat -c %a "$CFG" 2>/dev/null)"
      [ -n "$CPERM" ] && [ $(( 8#$CPERM & 4 )) -ne 0 ] && flag WARN "SimpleSAMLphp ($r): config.php leggibile da tutti (permessi $CPERM)"
    else
      note "config.php non presente o non leggibile: $CFG"
    fi

    # --- Moduli abilitati e metadata (solo nomi)
    note "--- Moduli abilitati (file 'enable')"
    for m in "$r"/modules/*/enable; do [ -e "$m" ] && note "  $(basename "$(dirname "$m")")"; done
    note "--- Metadata (solo nomi/permessi)"
    ls -la "$r/metadata" >> "$CUR" 2>&1

    # --- Certificati (scadenza) e chiavi private (solo permessi, mai il contenuto)
    note "--- Certificati e chiavi"
    for f in "$r"/cert/* "$r"/config/*.crt "$r"/config/*.pem; do
      [ -f "$f" ] || continue
      if grep -q "BEGIN CERTIFICATE" "$f" 2>/dev/null && have openssl; then
        note "$f: $(openssl x509 -in "$f" -noout -enddate -subject 2>&1 | tr '\n' ' ')"
        openssl x509 -in "$f" -noout -checkend 2592000 >/dev/null 2>&1 || flag WARN "SimpleSAMLphp: certificato in scadenza (<30gg) o scaduto: $f"
      fi
      if grep -qE "BEGIN ([A-Z]+ )?PRIVATE KEY" "$f" 2>/dev/null; then
        KP="$(stat -c %a "$f" 2>/dev/null)"
        note "$f: chiave privata, permessi $KP"
        [ -n "$KP" ] && [ $(( 8#$KP & 4 )) -ne 0 ] && flag FAIL "SimpleSAMLphp: chiave privata leggibile da tutti ($f, permessi $KP)"
      fi
    done
  done
  note ""; note "--- Riferimenti dei web server a simplesaml (Alias, SetEnv, location, fastcgi)"
  grep -rniE "simplesaml" /etc/apache2 /etc/httpd /etc/nginx /etc/lighttpd 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*#' | head -20 >> "$CUR"
  flag TODO "SimpleSAMLphp: verificare metadata IdP/SP, firma delle asserzioni e cifratura (dettagli in 16_simplesamlphp.txt)"
fi

# ============================== 17 ALBERO NAVIGABILE DELLE WEB ROOT (HTML) ===
# Adattato dallo script genera_albero_html.sh. Differenze rispetto all'originale:
#  - include i file nascosti (.git, .env, .htaccess...), che per l'audit sono i piu' interessanti
#  - non segue i link simbolici delle directory (evita cicli infiniti), li mostra come "link"
#  - escape HTML dei nomi (un nome file con < > & non rompe la pagina)
#  - evidenzia in rosso i nomi sensibili (.git, .env, backup, dump, chiavi, phpinfo...) e i
#    file/dir scrivibili da tutti (world-writable)
#  - non espande .git/.svn/node_modules (migliaia di file inutili); limite di voci per albero
#  - genera anche un elenco testuale con permessi, proprietario, dimensione e data
sec 17_albero_web_root.txt "ALBERO NAVIGABILE DELLE WEB ROOT (HTML)"
shopt -u patsub_replacement 2>/dev/null     # bash 5.2: '&' nelle sostituzioni sarebbe speciale

TREE_MAX="${NIS2_TREE_MAX:-20000}"          # numero massimo di voci per albero
TREE_DIR="$OUT/albero_web"
declare -A TREE_WW
TREE_N=0; TREE_FLAG=0; TREE_WWN=0; TREE_TRUNC=0; TREE_BASE=""

tree_esc() { local s="$1"; s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"; REPLY="$s"; }
tree_url() { local s="$1"; s="${s//%/%25}"; s="${s// /%20}"; s="${s//#/%23}"; s="${s//\?/%3F}"; s="${s//\"/%22}"; s="${s//\'/%27}"; s="${s//</%3C}"; s="${s//>/%3E}"; REPLY="$s"; }

# nomi sensibili (argomento gia' in minuscolo)
tree_sensitive() {
  case "$1" in
    .git|.svn|.hg|.env|.env.*|.htpasswd|.ds_store|phpinfo*.php|info.php|test.php|adminer*|phpmyadmin) return 0 ;;
    id_rsa|id_dsa|id_ecdsa|id_ed25519|*.pem|*.key|*.pfx|*.p12|*.jks) return 0 ;;
    *.bak|*.old|*.orig|*.swp|*~|*.sql|*.sql.gz|*.dump|*.zip|*.tar|*.tar.gz|*.tgz|*.rar|*.7z|*.log) return 0 ;;
    config.php.*|wp-config.php.*|*.php.bak|*.php~) return 0 ;;
  esac
  return 1
}

# tree_walk DIR RELPATH  -> scrive i <li> su stdout (richiede dotglob+nullglob attivi)
tree_walk() {
  local dir="$1" rel="$2" item name lname crel cls en url
  local -a dirs=() files=()
  for item in "$dir"/*; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    if [ -d "$item" ] && [ ! -L "$item" ]; then dirs+=("$item"); else files+=("$item"); fi
  done
  if [ "${#dirs[@]}" -gt 0 ]; then
    for item in "${dirs[@]}"; do
      [ "$TREE_N" -ge "$TREE_MAX" ] && { TREE_TRUNC=1; echo '<li class="note">elenco troncato: limite di voci raggiunto</li>'; return; }
      TREE_N=$((TREE_N+1))
      name="${item##*/}"; lname="${name,,}"; crel="${rel:+$rel/}$name"
      cls="folder"
      if tree_sensitive "$lname"; then cls="$cls bad"; TREE_FLAG=$((TREE_FLAG+1)); fi
      if [ -n "${TREE_WW[$item]:-}" ]; then cls="$cls ww"; TREE_WWN=$((TREE_WWN+1)); fi
      tree_esc "$name"; en="$REPLY"
      echo "<li class=\"$cls\"><span>$en/</span><ul class=\"nested\">"
      case "$lname" in
        .git|.svn|.hg|node_modules) echo '<li class="note">contenuto non espanso</li>' ;;
        *) tree_walk "$item" "$crel" ;;
      esac
      echo "</ul></li>"
    done
  fi
  if [ "${#files[@]}" -gt 0 ]; then
    for item in "${files[@]}"; do
      [ "$TREE_N" -ge "$TREE_MAX" ] && { TREE_TRUNC=1; echo '<li class="note">elenco troncato: limite di voci raggiunto</li>'; return; }
      TREE_N=$((TREE_N+1))
      name="${item##*/}"; lname="${name,,}"; crel="${rel:+$rel/}$name"
      cls="file"
      if tree_sensitive "$lname"; then cls="$cls bad"; TREE_FLAG=$((TREE_FLAG+1)); fi
      if [ -n "${TREE_WW[$item]:-}" ]; then cls="$cls ww"; TREE_WWN=$((TREE_WWN+1)); fi
      tree_esc "$name"; en="$REPLY"
      if [ -L "$item" ]; then
        tree_esc "$(readlink "$item" 2>/dev/null)"
        echo "<li class=\"link $cls\">$en &rarr; $REPLY</li>"
      else
        tree_url "$crel"; url="$REPLY"; tree_esc "$TREE_BASE/$url"
        echo "<li class=\"$cls\"><a href=\"$REPLY\" target=\"_blank\" rel=\"noopener\">$en</a></li>"
      fi
    done
  fi
}

# gen_tree DIR BASE_URL OUTFILE
gen_tree() {
  local root="$1" base="$2" out="$3" body="$3.body" p oldd=0 oldn=0 eroot ebase
  TREE_N=0; TREE_FLAG=0; TREE_WWN=0; TREE_TRUNC=0; TREE_BASE="${base%/}"; TREE_WW=()
  while IFS= read -r p; do TREE_WW["$p"]=1; done < <(find "$root" -xdev -perm -0002 ! -type l 2>/dev/null | head -n 20000)
  shopt -q dotglob  && oldd=1; shopt -q nullglob && oldn=1
  shopt -s dotglob nullglob
  tree_walk "$root" "" > "$body"
  [ "$oldd" -eq 0 ] && shopt -u dotglob; [ "$oldn" -eq 0 ] && shopt -u nullglob
  tree_esc "$root"; eroot="$REPLY"; tree_esc "$TREE_BASE"; ebase="$REPLY"
  cat > "$out" <<EOF
<!DOCTYPE html>
<html lang="it">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Albero web root: $eroot</title>
<style>
  body { font-family: Arial, sans-serif; background:#f9f9f9; color:#333; margin:20px; }
  .tree-container { background:#fff; border:1px solid #ddd; border-radius:6px; padding:15px; max-width:1000px; box-shadow:0 2px 4px rgba(0,0,0,.05); }
  .stats { font-size:.9em; margin-bottom:10px; } .stats b.red { color:#b00020; }
  button { margin-right:6px; padding:3px 10px; cursor:pointer; }
  ul.tree, ul.tree ul { list-style:none; padding-left:20px; margin:4px 0; } ul.tree { padding-left:0; }
  li.folder > span { cursor:pointer; font-weight:bold; color:#0056b3; user-select:none; }
  li.folder > span::before { content:'\1F4C1  '; } li.folder.open > span::before { content:'\1F4C2  '; }
  li.file, li.link { margin:3px 0; } li.file::before { content:'\1F4C4  '; } li.link::before { content:'\1F517  '; }
  li.file a { color:#222; text-decoration:none; } li.file a:hover { text-decoration:underline; color:#0056b3; }
  li.note { color:#888; font-style:italic; margin:3px 0; }
  .bad > span, li.bad > a, li.bad { color:#b00020 !important; font-weight:bold; }
  .ww::after { content:'  [scrivibile da tutti]'; color:#b00020; font-size:.8em; }
  .nested { display:none; } .active { display:block; }
</style>
</head>
<body>
<h2>Indice file per: $eroot</h2>
<div class="stats">Base URL dei link: <code>$ebase</code> &middot; voci: <b>$TREE_N</b> &middot;
  nomi sensibili: <b class="red">$TREE_FLAG</b> &middot; scrivibili da tutti: <b class="red">$TREE_WWN</b>
  $( [ "$TREE_TRUNC" -eq 1 ] && echo '&middot; <b class="red">elenco troncato</b>' )
  <br>Generato il $(date '+%Y-%m-%d %H:%M') da nis2_collect.sh. Contiene solo nomi di file, non contenuti.</div>
<p><button id="expAll">Espandi tutto</button><button id="colAll">Comprimi tutto</button></p>
<div class="tree-container">
<ul class="tree">
<li class="folder open"><span>$eroot</span>
<ul class="nested active">
EOF
  cat "$body" >> "$out"
  cat >> "$out" <<'EOF'
</ul>
</li>
</ul>
</div>
<script>
document.addEventListener("DOMContentLoaded", function() {
  var spans = document.querySelectorAll(".tree li.folder > span");
  spans.forEach(function(s) {
    s.addEventListener("click", function(e) {
      var li = this.parentElement, ul = li.querySelector(":scope > .nested");
      if (ul) { ul.classList.toggle("active"); li.classList.toggle("open"); }
      e.stopPropagation();
    });
  });
  function setAll(open) {
    document.querySelectorAll(".tree li.folder").forEach(function(li) {
      var ul = li.querySelector(":scope > .nested");
      if (ul) { ul.classList.toggle("active", open); li.classList.toggle("open", open); }
    });
  }
  document.getElementById("expAll").onclick = function() { setAll(true); };
  document.getElementById("colAll").onclick = function() { setAll(false); };
});
</script>
</body>
</html>
EOF
  rm -f "$body"
}

if [ "$SKIP_TREE" -eq 1 ]; then
  note "Generazione dell'albero saltata (-T)"
  flag INFO "Albero web root: saltato su richiesta (-T)"
else
  mkdir -p "$TREE_DIR" && chmod 700 "$TREE_DIR"
  # Radici: DocumentRoot rilevati (Apache/Nginx/Lighttpd); fallback /var/www/html. Si tengono solo quelle
  # piu' esterne (una radice annidata in un'altra e' gia' inclusa nell'albero della radice che la contiene).
  [ -s "$DOCROOT_FILE" ] || { [ -d /var/www/html ] && printf '/var/www/html\t-\tdefault\n' >> "$DOCROOT_FILE"; }
  declare -a KEEP_DR=() KEEP_SN=()
  KN=0
  while IFS=$'\t' read -r dr sn typ; do
    case "$dr" in ''|*'$'*) continue ;; esac
    [ -d "$dr" ] || continue
    dr="$(readlink -f "$dr" 2>/dev/null)"; [ -n "$dr" ] || continue
    dup=0; i=0
    while [ "$i" -lt "$KN" ]; do
      case "$dr/" in "${KEEP_DR[$i]}"/*)
        dup=1
        [ "$dr" = "${KEEP_DR[$i]}" ] && [ "${KEEP_SN[$i]}" = "-" ] && KEEP_SN[$i]="$sn" ;;
      esac
      i=$((i+1))
    done
    [ "$dup" -eq 1 ] && continue
    [ "$KN" -ge 10 ] && { note "Limite di 10 web root raggiunto: $dr non incluso"; continue; }
    KEEP_DR[$KN]="$dr"; KEEP_SN[$KN]="$sn"; KN=$((KN+1))
  done < <(awk -F'\t' '{print length($1) "\t" $0}' "$DOCROOT_FILE" | sort -n | cut -f2-)

  if [ "$KN" -eq 0 ]; then
    note "Nessuna web root da elencare (nessun DocumentRoot esistente rilevato)"
    flag INFO "Albero web root: nessuna web root rilevata"
  else
    INDEX="$TREE_DIR/index.html"
    { echo '<!DOCTYPE html><html lang="it"><head><meta charset="UTF-8"><title>Alberi web root</title></head><body style="font-family:Arial,sans-serif;margin:20px">'
      echo "<h2>Alberi delle web root &ndash; $(hostname -s 2>/dev/null)</h2><ul>"; } > "$INDEX"
    i=0
    while [ "$i" -lt "$KN" ]; do
      dr="${KEEP_DR[$i]}"; sn="${KEEP_SN[$i]}"
      if [ -n "$TREE_BASEURL" ]; then bu="${TREE_BASEURL%/}"
      elif [ "$sn" != "-" ] && [ "$sn" != "_" ] && [ "${sn#*[\$*]}" = "$sn" ]; then bu="https://$sn"
      else bu="https://$HOST_FQDN"; fi
      san="$(printf '%s' "$dr" | sed 's|^/||; s|[^A-Za-z0-9._-]|_|g')"
      f="albero_${san}.html"
      note "Albero: $dr  (base URL $bu)  ->  albero_web/$f"
      gen_tree "$dr" "$bu" "$TREE_DIR/$f"
      find "$dr" -xdev -printf '%M %u:%g %10s %TY-%Tm-%Td %p\n' 2>/dev/null | head -n $((TREE_MAX * 2)) > "$TREE_DIR/elenco_${san}.txt"
      note "   voci: $TREE_N | nomi sensibili: $TREE_FLAG | scrivibili da tutti: $TREE_WWN | troncato: $TREE_TRUNC"
      tree_esc "$dr"
      echo "<li><a href=\"$f\">$REPLY</a> &mdash; voci $TREE_N, sensibili $TREE_FLAG, world-writable $TREE_WWN &mdash; <a href=\"elenco_${san}.txt\">elenco con permessi</a></li>" >> "$INDEX"
      if [ "$TREE_FLAG" -gt 0 ] || [ "$TREE_WWN" -gt 0 ]; then
        flag WARN "Albero web root $dr: $TREE_FLAG nomi sensibili, $TREE_WWN elementi world-writable (evidenziati in rosso in albero_web/$f)"
      fi
      [ "$TREE_TRUNC" -eq 1 ] && flag INFO "Albero web root $dr: elenco troncato a $TREE_MAX voci (variabile NIS2_TREE_MAX)"
      i=$((i+1))
    done
    echo "</ul></body></html>" >> "$INDEX"
    flag INFO "Alberi navigabili delle web root generati in albero_web/ ($KN radice/i): aprire albero_web/index.html"
  fi
fi

# ======================================================= CHIUSURA ============
{
  echo
  echo "TODO MANUALI (non rilevabili da script):"
  echo " - Verifica EOL di OS / PHP / MariaDB / Apache su https://endoflife.date"
  echo " - Test di ripristino backup, RPO/RTO documentati"
  echo " - Procedura notifica incidenti CSIRT Italia (24h preallarme / 72h notifica)"
  echo " - Registro asset, ruoli, policy approvate dagli organi di vertice, formazione"
  echo " - Inventario fornitori / supply chain e contratti"
  echo " - MFA sugli accessi privilegiati / remoti (VPN, SSH, pannelli di amministrazione)"
  echo " - Analisi applicativa: Semgrep, PHPStan/Psalm, Gitleaks, OWASP ZAP, retire.js"
} >> "$SUMMARY"

# Riepilogo ordinato per gravità in testa al file
{
  echo "NIS2/ACN - RACCOLTA EVIDENZE v$VERSION"
  echo "Host: $HOST   Data: $(date -Is)   Eseguito da: $(id -un) (uid $(id -u))"
  echo "Legenda: FAIL=non conforme/critico  WARN=da verificare  OK=positivo  INFO=dato  TODO=azione manuale"
  echo "--------------------------------------------------------------------"
  for l in FAIL WARN OK INFO TODO; do grep "^\[$l" "$SUMMARY"; done
  echo "--------------------------------------------------------------------"
  sed -n '/^TODO MANUALI/,$p' "$SUMMARY"
} > "$SUMMARY.tmp" && mv "$SUMMARY.tmp" "$SUMMARY"

# Archivio + hash di integrità
step "Archivio finale e hash SHA256"
chmod -R go-rwx "$OUT" 2>/dev/null
ARCH="${OUT}.tar.gz"
tar -czf "$ARCH" -C "$(dirname "$OUT")" "$(basename "$OUT")" 2>/dev/null; TAR_RC=$?
spin_stop
if [ "$TAR_RC" -eq 0 ]; then
  have sha256sum && sha256sum "$ARCH" > "${ARCH}.sha256"
  echo
  echo "Completato in ${SECONDS}s. Archivio: $ARCH"
  have sha256sum && echo "SHA256: $(cut -d' ' -f1 "${ARCH}.sha256")"
else
  echo "ATTENZIONE: creazione dell'archivio non riuscita (codice $TAR_RC). I report sono comunque in: $OUT/"
fi
echo
echo "== Riepilogo =="; grep -E '^\[(FAIL|WARN)' "$SUMMARY" | head -40
echo
echo "Dettagli completi in: $OUT/"
echo "NOTA: l'archivio contiene informazioni sensibili sull'infrastruttura. Conservalo cifrato e con accesso ristretto."
