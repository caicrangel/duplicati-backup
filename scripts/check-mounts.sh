#!/bin/bash
#
# check-mounts.sh
# Verifica se os pontos de montagem estao montados, acessiveis e populados.
# Se nao estiverem, remonta usando as definicoes do /etc/fstab.
# Ao final, envia relatorio formatado para o Telegram.
#
# Nao usa arquivo sentinela: a validacao e feita pelo tipo de sistema de
# arquivos e pela quantidade minima de itens encontrados no ponto.
#
# Requisito: cada ponto listado abaixo precisa ter entrada no /etc/fstab.
# Uso: crontab do root, antes do horario do backup do Duplicati.
#

set -u

# Diretorio onde o script esta instalado (log e .telegram ficam ao lado)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==================== CONFIGURACAO ====================
# Formato: "PONTO_DE_MONTAGEM|FSTYPE_ESPERADO"
# Origem e opcoes de montagem vem do /etc/fstab.
# Ajuste para os shares do seu servidor de arquivos.
MOUNTS=(
  "/mnt/fileserver/usuarios|cifs"
  "/mnt/fileserver/publico|cifs"
  # "/mnt/fileserver/outro-share|cifs"
  # "/mnt/outro-servidor/share|nfs4"
)

# Numero minimo de itens no ponto para considerar o conteudo valido.
MIN_ITENS=2

LOG="${SCRIPT_DIR}/log/check-mounts.log"
TIMEOUT=15          # segundos ate considerar o mount travado
TENTATIVAS=3        # tentativas de montagem por ponto
INTERVALO=10        # segundos entre tentativas

# Alerta se o sistema foi reiniciado ha menos de X segundos (3600 = 1h)
BOOT_RECENTE=3600

# -------------------- TELEGRAM ------------------------
# Recomendado: manter as credenciais fora deste arquivo.
# Copie check-mounts.env.example para check-mounts.env (permissao 600) contendo:
#   TG_BOT_TOKEN="123456:ABC-DEF..."
#   TG_CHAT_ID="-1001234567890"
TG_CONF="${SCRIPT_DIR}/check-mounts.env"
[ -r "$TG_CONF" ] && . "$TG_CONF"

TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"

# Quando notificar: "sempre" ou "falha"
TG_NOTIFICAR="sempre"
# ======================================================

mkdir -p "$(dirname "$LOG")"
log() { echo "$(date '+%F %T') | $*" | tee -a "$LOG"; }

# Linhas que compoem o relatorio enviado ao Telegram
RELATORIO=()
rel() { RELATORIO+=("$1"); }

# Escapa os caracteres reservados do parse_mode HTML
esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

enviar_telegram() {
  local TEXTO="$1"

  if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
    log "AVISO: credenciais do Telegram ausentes. Notificacao ignorada."
    return 0
  fi

  local HTTP
  HTTP=$(curl -sS -m 20 -o /tmp/tg_resp.$$ -w '%{http_code}' \
    -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    -d "parse_mode=HTML" \
    -d "disable_web_page_preview=true" \
    --data-urlencode "text=${TEXTO}" 2>>"$LOG")

  if [ "$HTTP" = "200" ]; then
    log "Telegram: notificacao enviada."
  else
    log "ERRO: Telegram retornou HTTP $HTTP -> $(cat /tmp/tg_resp.$$ 2>/dev/null)"
  fi
  rm -f /tmp/tg_resp.$$
}

# Execucao unica: evita sobreposicao entre chamadas do cron
exec 9>/var/lock/check-mounts.lock
if ! flock -n 9; then
  log "AVISO: outra instancia em execucao. Saindo."
  exit 0
fi

# Verifica se o ponto responde de fato (montado != acessivel)
acessivel() { timeout "$TIMEOUT" ls "$1" >/dev/null 2>&1; }

# Confirma que o filesystem montado e o esperado (e nao o disco local)
fstype_ok() {
  local T
  T=$(findmnt -no FSTYPE --target "$1" 2>/dev/null)
  [ "$T" = "$2" ]
}

# Conta itens sem percorrer o diretorio inteiro
populado() {
  local N
  N=$(timeout "$TIMEOUT" ls -A "$1" 2>/dev/null | head -n $((MIN_ITENS + 1)) | wc -l)
  [ "$N" -ge "$MIN_ITENS" ]
}

# Espaco livre no ponto, para enriquecer o relatorio
uso_disco() {
  timeout "$TIMEOUT" df -h --output=size,used,avail,pcent "$1" 2>/dev/null | tail -1 | tr -s ' '
}

# Data do ultimo boot e tempo decorrido desde entao
info_boot() {
  local BOOT UP
  BOOT=$(uptime -s 2>/dev/null)
  if [ -n "$BOOT" ]; then
    BOOT=$(date -d "$BOOT" '+%d/%m/%Y às %H:%M' 2>/dev/null || echo "$BOOT")
  else
    BOOT="n/d"
  fi
  UP=$(uptime -p 2>/dev/null | sed -e 's/^up /há /' \
        -e 's/ weeks\?/ semanas/' -e 's/ days\?/ dias/' \
        -e 's/ hours\?/h/' -e 's/ minutes\?/min/')
  printf '%s · %s' "$BOOT" "${UP:-n/d}"
}

# Segundos desde o ultimo boot (0 se nao for possivel determinar)
segundos_desde_boot() {
  local B
  B=$(uptime -s 2>/dev/null) || { echo 0; return; }
  [ -z "$B" ] && { echo 0; return; }
  echo $(( $(date +%s) - $(date -d "$B" +%s 2>/dev/null || date +%s) ))
}

montar() {
  local DST="$1"
  for (( i=1; i<=TENTATIVAS; i++ )); do
    log "Tentativa $i/$TENTATIVAS: mount $DST"
    if mount "$DST" >>"$LOG" 2>&1 && acessivel "$DST"; then
      log "OK: $DST montado e acessivel."
      return 0
    fi
    [ "$i" -lt "$TENTATIVAS" ] && sleep "$INTERVALO"
  done
  return 1
}

INICIO=$(date +%s)
FALHAS=0
REMONTADOS=0

log "=== Inicio da verificacao | ultimo boot: $(info_boot) ==="

for LINHA in "${MOUNTS[@]}"; do
  IFS='|' read -r DST FSTYPE <<< "$LINHA"
  DST_E=$(esc "$DST")

  # Pre-checagem: existe entrada no fstab?
  if ! grep -qE "^[^#].*[[:space:]]${DST}[[:space:]]" /etc/fstab; then
    log "ERRO: $DST nao possui entrada no /etc/fstab."
    rel "❌ <b>${DST_E}</b>"
    rel "     └ sem entrada no <code>/etc/fstab</code>"
    FALHAS=1
    continue
  fi

  ESTADO=""

  if ! mountpoint -q "$DST"; then
    log "AVISO: $DST NAO esta montado."
    if montar "$DST"; then
      ESTADO="remontado"
      REMONTADOS=1
    else
      log "ERRO: falha ao montar $DST."
      rel "❌ <b>${DST_E}</b>"
      rel "     └ falha ao montar após ${TENTATIVAS} tentativas"
      FALHAS=1
      continue
    fi

  elif ! acessivel "$DST"; then
    log "AVISO: $DST montado porem inacessivel (timeout/IO). Remontando..."
    umount -f "$DST" >>"$LOG" 2>&1 || umount -l "$DST" >>"$LOG" 2>&1
    sleep 3
    if montar "$DST"; then
      ESTADO="recuperado"
      REMONTADOS=1
    else
      log "ERRO: $DST continua inacessivel."
      rel "❌ <b>${DST_E}</b>"
      rel "     └ montado porém inacessível (timeout de I/O)"
      FALHAS=1
      continue
    fi

  else
    log "OK: $DST ja montado e acessivel."
    ESTADO="estável"
  fi

  # Validacao sem sentinela
  if ! fstype_ok "$DST" "$FSTYPE"; then
    ATUAL=$(findmnt -no FSTYPE --target "$DST" 2>/dev/null)
    log "ERRO: $DST e '${ATUAL:-desconhecido}', esperado '$FSTYPE'. Montagem incorreta."
    rel "❌ <b>${DST_E}</b>"
    rel "     └ tipo <code>$(esc "${ATUAL:-desconhecido}")</code>, esperado <code>$(esc "$FSTYPE")</code>"
    FALHAS=1
  elif ! populado "$DST"; then
    log "ERRO: $DST com menos de $MIN_ITENS itens. Conteudo suspeito."
    rel "❌ <b>${DST_E}</b>"
    rel "     └ menos de ${MIN_ITENS} itens — conteúdo suspeito"
    FALHAS=1
  else
    log "OK: $DST validado ($FSTYPE, conteudo presente)."
    USO=$(uso_disco "$DST")
    rel "✅ <b>${DST_E}</b>"
    rel "     ├ tipo: <code>$(esc "$FSTYPE")</code> · ${ESTADO}"
    rel "     └ uso: <code>$(esc "${USO:-n/d}")</code>"
  fi

done

# Aviso de boot recente: causa comum de share desmontado
BOOT_SEG=$(segundos_desde_boot)
if [ "$BOOT_SEG" -gt 0 ] && [ "$BOOT_SEG" -lt "$BOOT_RECENTE" ]; then
  rel ""
  rel "⚠️ <i>Sistema reiniciado há menos de $((BOOT_RECENTE / 60)) min</i>"
  log "AVISO: boot recente (${BOOT_SEG}s)."
fi

DURACAO=$(( $(date +%s) - INICIO ))

# ==================== RELATORIO ====================
if [ "$FALHAS" -ne 0 ]; then
  CABECALHO="🔴 <b>FALHA NA VERIFICAÇÃO</b>"
  RODAPE="⚠️ <i>Backup não deve ser executado. Verifique o servidor de arquivos.</i>"
  log "RESULTADO: FALHA. Verifique o servidor de arquivos antes do backup."
elif [ "$REMONTADOS" -eq 1 ]; then
  CABECALHO="🟡 <b>RECUPERADO</b>"
  RODAPE="ℹ️ <i>Houve remontagem. Pontos operacionais para o backup.</i>"
  log "RESULTADO: todos os pontos OK (com remontagem)."
else
  CABECALHO="🟢 <b>TUDO OK</b>"
  RODAPE="✔️ <i>Pontos prontos para o backup.</i>"
  log "RESULTADO: todos os pontos OK."
fi

MSG="${CABECALHO}
<b>Verificação de Montagens</b>

🖥 Host: <code>$(esc "$(hostname)")</code>
🔄 Último boot: <code>$(esc "$(info_boot)")</code>
🕒 $(date '+%d/%m/%Y às %H:%M:%S')

━━━━━━━━━━━━━━━━━━━━
$(printf '%s\n' "${RELATORIO[@]}")
━━━━━━━━━━━━━━━━━━━━

📊 Pontos: ${#MOUNTS[@]} · Falhas: ${FALHAS} · Duração: ${DURACAO}s

${RODAPE}"

if [ "$TG_NOTIFICAR" = "sempre" ] || [ "$FALHAS" -ne 0 ]; then
  enviar_telegram "$MSG"
fi

[ "$FALHAS" -ne 0 ] && exit 1
exit 0
