#!/bin/bash

#########################################################################
# notify_to_telegram.sh
# Envia ao Telegram o relatorio de execucao dos jobs do Duplicati.
#
# INTEGRACAO
#   O Duplicati executa scripts antes e depois de cada operacao. Configure
#   nas opcoes avancadas do job (interface web) ou via CLI:
#     --run-script-before = /scripts/notify_to_telegram.sh
#     --run-script-after  = /scripts/notify_to_telegram.sh
#
#   Neste stack a pasta ./scripts do host e montada como /scripts (somente
#   leitura) dentro do container do Duplicati — veja o docker-compose.yml.
#
# CONFIGURACAO
#   Requer duas variaveis, definidas em 'telegram_config.env' no mesmo
#   diretorio deste script, ou exportadas no ambiente:
#     TELEGRAM_TOKEN    token do bot
#     TELEGRAM_CHATID   ID do chat/grupo de destino
#
# ENTRADA
#   O Duplicati expoe o contexto da operacao em variaveis de ambiente
#   (DUPLICATI__EVENTNAME, DUPLICATI__OPERATIONNAME, DUPLICATI__PARSED_RESULT,
#   DUPLICATI__RESULTFILE, DUPLICATI__backup_name), consumidas abaixo.
#
# SAIDA
#   Mensagem HTML enviada via API do Telegram. Sempre encerra com codigo 0
#   para nao interferir no resultado do job.
#########################################################################

# 1. Diretorio do proprio script: o arquivo de configuracao e lido daqui,
#    independente do diretorio de trabalho de quem invocou o script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_FILE="${SCRIPT_DIR}/telegram_config.env"

# 2. Carrega as variaveis do arquivo de configuracao, removendo quebras de
#    linha CRLF (\r) para tolerar arquivos editados no Windows.
if [ -f "$CONFIG_FILE" ]; then
    source <(tr -d '\r' < "$CONFIG_FILE")
fi

# 3. Valida as variaveis obrigatorias (do arquivo ou herdadas do ambiente)
if [ -z "$TELEGRAM_TOKEN" ] || [ -z "$TELEGRAM_CHATID" ]; then
    echo "ERRO: TELEGRAM_TOKEN ou TELEGRAM_CHATID nao configurado!" >&2
    echo "Crie o arquivo 'telegram_config.env' no mesmo diretorio do script" >&2
    echo "ou exporte as variaveis correspondentes no ambiente." >&2
    exit 1
fi

TELEGRAM_URL="https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage"

# -----------------------------------------------------------------------
# PARSER SEGURO DO ARQUIVO DE RESULTADO
# Le linhas no formato "Chave: Valor" e atribui cada valor a uma variavel
# de mesmo nome via `printf -v`, que nunca executa o conteudo. Apenas chaves
# que sejam nomes validos de variavel sao aceitas, de modo que nomes de
# arquivos/pastas com metacaracteres de shell nao possam ser interpretados
# como codigo (evita injecao de comando via nome de arquivo).
# -----------------------------------------------------------------------
function parseResultFile() {
    local file="$1"
    local line key value
    [ -f "$file" ] && [ -r "$file" ] || return 0
    while IFS= read -r line; do
        # Casa "Chave: Valor" com Chave sendo um nome valido de variavel
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*):[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            value="${value%$'\r'}"   # remove CR final (quebra de linha Windows)
            printf -v "$key" '%s' "$value"
        fi
    done < "$file"
}

# Converte tamanhos em bytes para formato legivel (Kb/Mb/Gb/Tb)
function getFriendlyFileSize() {
    local size="$1"
    case "$size" in
        ''|*[!0-9]*)
            size=0
            ;;
    esac
    if [ "$size" -eq 0 ]; then
        echo '-'
    elif [ "$size" -ge 1099511627776 ]; then
        awk 'BEGIN {printf "%.1f",'$size'/1099511627776}' && echo 'Tb'
    elif [ "$size" -ge 1073741824 ]; then
        awk 'BEGIN {printf "%.1f",'$size'/1073741824}' && echo 'Gb'
    elif [ "$size" -ge 1048576 ]; then
        awk 'BEGIN {printf "%.1f",'$size'/1048576}' && echo 'Mb'
    elif [ "$size" -ge 1024 ]; then
        awk 'BEGIN {printf "%.1f",'$size'/1024}' && echo 'Kb'
    else
        echo '-'
    fi
}

# Monta o cabecalho do relatorio (tarefa, operacao, status e icone do resultado)
function getResultLine () {
    CURRENT_STATUS=`echo "BEFORE=Iniciado,AFTER=Concluído" | sed "s/.*$DUPLICATI__EVENTNAME=\([^,]*\).*/\1/"`
    RESULT_ICON=`echo "Unknown=🟣,Success=✅,Warning=⚠️,Error=❌,Fatal=💥" | sed "s/.*$DUPLICATI__PARSED_RESULT=\([^,]*\).*/\1/"`
    local RESULT_TEXT=`echo "Unknown=Desconhecido,Success=Sucesso,Warning=Alerta,Error=Erro,Fatal=Fatal" | sed "s/.*$DUPLICATI__PARSED_RESULT=\([^,]*\).*/\1/"`
    local output="<b>💾 DUPLICATI BACKUP</b>
<pre>
———————————————————————————————
📋 <b>Tarefa:</b>     $DUPLICATI__backup_name
⚙️ <b>Operação:</b>   $DUPLICATI__OPERATIONNAME
📊 <b>Status:</b>     $CURRENT_STATUS
${RESULT_ICON} <b>Resultado:</b>  $RESULT_TEXT
———————————————————————————————
⏱ <b>Duração:</b>    $Duration
———————————————————————————————"
    echo "$output" | sed 's/^[ \t]*//;s/[ \t]*$//'
}

# Bloco de detalhes para operacoes com resultado Fatal
function getResultFatal () {
    parseResultFile "$DUPLICATI__RESULTFILE"
    local output="
❗ <b>Erro:</b> $Failed
📋 <b>Detalhes:</b> $Details"
    echo "$output" | sed 's/^[ \t]*//;s/[ \t]*$//'
}

# Bloco de estatisticas para operacoes de restauracao
function getOperationRestore () {
    parseResultFile "$DUPLICATI__RESULTFILE"
    local output="
📂 <b>ARQUIVOS:</b>     qtde       tam.
📥 <b>Restaurados:</b> $(printf %7s $RestoredFiles) $(printf %10s $(getFriendlyFileSize $SizeOfRestoredFiles))
🗑️ <b>Excluídos:</b>   $(printf %7s $DeletedFiles) $(printf %10s $(getFriendlyFileSize 0))
🛠️ <b>Corrigidos:</b>  $(printf %7s $PatchedFiles) $(printf %10s $(getFriendlyFileSize 0))
———————————————————————————————
📁 <b>PASTAS:</b>
📂 <b>Restauradas:</b> $(printf %7s $RestoredFolders) $(printf %10s $(getFriendlyFileSize 0))
🗑️ <b>Excluídas:</b>   $(printf %7s $DeletedFolders) $(printf %10s $(getFriendlyFileSize 0))"
    echo "$output" | sed 's/^[ \t]*//;s/[ \t]*$//'
}

# Bloco de estatisticas para operacoes de backup
function getOperationBackup () {
    parseResultFile "$DUPLICATI__RESULTFILE"
    local output="
📂 <b>ARQUIVOS:</b>     qtde       tam.
➕ <b>Adicionados:</b> $(printf %7s $AddedFiles) $(printf %10s $(getFriendlyFileSize $SizeOfAddedFiles))
➖ <b>Excluídos:</b>   $(printf %7s $DeletedFiles) $(printf %10s $(getFriendlyFileSize 0))
🔧 <b>Alterados:</b>   $(printf %7s $ModifiedFiles) $(printf %10s $(getFriendlyFileSize $SizeOfModifiedFiles))
🔍 <b>Abertos:</b>     $(printf %7s $OpenedFiles) $(printf %10s $(getFriendlyFileSize $SizeOfOpenedFiles))
🔎 <b>Examinados:</b>  $(printf %7s $ExaminedFiles) $(printf %10s $(getFriendlyFileSize $SizeOfExaminedFiles))
———————————————————————————————
📁 <b>PASTAS:</b>
➕ <b>Adicionadas:</b> $(printf %7s $AddedFolders) $(printf %10s $(getFriendlyFileSize 0))
➖ <b>Excluídas:</b>   $(printf %7s $DeletedFolders) $(printf %10s $(getFriendlyFileSize 0))
🔧 <b>Alteradas:</b>   $(printf %7s $ModifiedFolders) $(printf %10s $(getFriendlyFileSize 0))"
    echo "$output" | sed 's/^[ \t]*//;s/[ \t]*$//'
}

# Ignora operacoes de listagem (nao representam execucao de backup)
if [ "$DUPLICATI__OPERATIONNAME" == "List" ]; then exit 0; fi

# Monta o conteudo da mensagem conforme o evento e a operacao
if [ "$DUPLICATI__EVENTNAME" == "AFTER" ]; then
    Duration=$(grep -oP '^Duration:\s*\K.*' "$DUPLICATI__RESULTFILE" | sed 's/\.[0-9]*$//' | tr -d '\r')
    [ -z "$Duration" ] && Duration="--:--:--"
    MESSAGE=$(getResultLine)
    if [ "$DUPLICATI__OPERATIONNAME" == "Restore" ]; then
        MESSAGE+=$(getOperationRestore)
    elif [ "$DUPLICATI__PARSED_RESULT" == "Fatal" ]; then
        MESSAGE+=$(getResultFatal)
    else
        MESSAGE+=$(getOperationBackup)
    fi
else
    CURRENT_STATUS=`echo "BEFORE=Iniciado,AFTER=Concluído" | sed "s/.*$DUPLICATI__EVENTNAME=\([^,]*\).*/\1/"`
    MESSAGE="<b>💾 DUPLICATI BACKUP</b>
<pre>
———————————————————————————————
📋 <b>Tarefa:</b>     $DUPLICATI__backup_name
⚙️ <b>Operação:</b>   $DUPLICATI__OPERATIONNAME
📊 <b>Status:</b>     $CURRENT_STATUS
</pre>"
fi

# Envia a mensagem ao Telegram com formatacao HTML
MESSAGE+="
</pre>"
curl -s "$TELEGRAM_URL" -d "chat_id=$TELEGRAM_CHATID" -d "text=$MESSAGE" -d "parse_mode=HTML" > /dev/null

exit 0
