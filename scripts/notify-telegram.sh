#!/bin/bash

#########################################################################
# Enhanced Script for Telegram Notifications about Duplicati Backup Results
# Based on spupuz/duplicati-telegram-notifications.
# Released "AS IS" without any warranty of any kind.
#########################################################################

# Duplicati can run scripts before and after backups. This
# functionality is available in the advanced options of any backup job (UI) or
# as option (CLI). The (advanced) options to run scripts are
# --run-script-before = /scripts/notify-telegram.sh
# --run-script-after = /scripts/notify-telegram.sh
#
# Neste stack, a pasta ./scripts do host e montada como /scripts (somente
# leitura) dentro do container do Duplicati — veja o docker-compose.yml.

# To work, you need to set two required variables:
#  TELEGRAM_TOKEN
#  TELEGRAM_CHATID
# These variables must be configured in 'telegram_config.env' located
# in the same directory as the script, or set as environment variables.
#
# DISCLAIMER (AS IS):
# This script is provided "as is", without warranty of any kind, express or
# implied. In no event shall the authors or copyright holders be liable for
# any claim, damages, data loss or other liability arising from its use.
#########################################################################

# 1. Locate the script directory to load the relative configuration file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_FILE="${SCRIPT_DIR}/telegram_config.env"

# 2. Load variables from config file if it exists, cleaning Windows CRLF line endings (\r)
if [ -f "$CONFIG_FILE" ]; then
    source <(tr -d '\r' < "$CONFIG_FILE")
fi

# 3. Verify presence of required variables (loaded from config or inherited from env)
if [ -z "$TELEGRAM_TOKEN" ] || [ -z "$TELEGRAM_CHATID" ]; then
    echo "Error: TELEGRAM_TOKEN or TELEGRAM_CHATID is not configured!" >&2
    echo "Please create a 'telegram_config.env' file in the same directory as the script" >&2
    echo "or set the corresponding environment variables." >&2
    exit 1
fi

TELEGRAM_URL="https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage"

# -----------------------------------------------------------------------
# SAFE PARSER (replaces the previous `eval` usage)
# Reads "Key: Value" lines from the Duplicati result file and assigns each
# value to a shell variable of the same name using `printf -v`, which never
# executes the value. Only keys that are valid variable names are accepted,
# so a folder/file name containing shell metacharacters can no longer be
# interpreted as code.
# -----------------------------------------------------------------------
function parseResultFile() {
    local file="$1"
    local line key value
    [ -f "$file" ] && [ -r "$file" ] || return 0
    while IFS= read -r line; do
        # Match "Key: Value" where Key is a valid variable name
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*):[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            value="${value%$'\r'}"   # strip trailing CR (Windows line endings)
            printf -v "$key" '%s' "$value"
        fi
    done < "$file"
}

# Function to convert file sizes to human-readable format
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

# Function to generate the result line with appropriate icon
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

# Function to handle fatal errors
function getResultFatal () {
    parseResultFile "$DUPLICATI__RESULTFILE"
    local output="
❗ <b>Erro:</b> $Failed
📋 <b>Detalhes:</b> $Details"
    echo "$output" | sed 's/^[ \t]*//;s/[ \t]*$//'
}

# Function to handle restore operations
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

# Function to handle backup operations
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

# Skip if operation is List
if [ "$DUPLICATI__OPERATIONNAME" == "List" ]; then exit 0; fi

# Generate message content
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

# Send message to Telegram with HTML formatting
MESSAGE+="
</pre>"
curl -s "$TELEGRAM_URL" -d "chat_id=$TELEGRAM_CHATID" -d "text=$MESSAGE" -d "parse_mode=HTML" > /dev/null

exit 0
