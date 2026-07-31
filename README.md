# Stack de Backup — Duplicati + File Browser

Stack Docker Compose para backup de servidores de arquivos usando o
[Duplicati](https://duplicati.com/) (agendamento, versionamento e criptografia
dos backups) e o [File Browser](https://filebrowser.org/) (acesso web aos
arquivos restaurados).

O projeto é um **template genérico**: clone, ajuste o `.env` e suba em qualquer
servidor.

## Arquitetura / Fluxo

```
        Servidor de arquivos (NFS/CIFS/Samba)
                      │
              montado no HOST em
              ${FILESERVER_MOUNT}  (ex.: /mnt/fileserver)
                      │  bind ro + rslave
                      ▼
              ┌──────────────┐   backups agendados    ┌─────────────────────┐
              │   Duplicati  │ ─────────────────────► │ ./duplicati/backups │
              │  (porta 8900)│                        │  ou destino remoto  │
              └──────┬───────┘                        └─────────────────────┘
                     │ restauração para /backup-restore
                     ▼
        ./filebrowser/srv/restore
                     │
                     ▼
              ┌──────────────┐
              │ File Browser │  ◄── usuário baixa os arquivos restaurados
              │  (porta 8081)│      pelo navegador
              └──────────────┘
```

1. O share do servidor de arquivos é montado **no host** (ex.: `/mnt/fileserver`)
   e entra no container do Duplicati como `/fileserver`, **somente leitura**.
2. Antes do horário do backup, o cron do root executa
   [`scripts/check-mounts.sh`](scripts/check-mounts.sh): ele valida cada ponto
   de montagem (montado, acessível, tipo de filesystem correto e com conteúdo),
   remonta automaticamente o que estiver caído e envia o relatório para o
   Telegram. Isso evita o cenário clássico de **backup "bem-sucedido" sem
   nenhum dado** porque o share estava desmontado.
3. O Duplicati executa os jobs de backup (origem: `/fileserver`; destino:
   `/backups` local ou um destino remoto — S3, SFTP, Google Drive etc.).
4. Ao final de cada job, o Duplicati executa
   [`scripts/notify-telegram.sh`](scripts/notify-telegram.sh)
   (opção `run-script-after`) e envia a **devolutiva do backup** para o
   Telegram: resultado (✅/⚠️/❌/💥), duração e estatísticas de arquivos e
   pastas processados.
5. Quando é preciso restaurar algo, restaura-se para `/backup-restore`, que é a
   mesma pasta servida pelo File Browser (`/srv/restore`) — o usuário baixa os
   arquivos pelo navegador, sem acesso ao servidor.

## Estrutura do repositório

```
.
├── docker-compose.yml      # Definição dos serviços
├── .env.example            # Modelo de variáveis (copiar para .env)
├── scripts/
│   ├── check-mounts.sh     # Valida/remonta os shares antes do backup (roda no host)
│   ├── .telegram.example   # Credenciais do check-mounts (copiar para .telegram)
│   ├── notify-telegram.sh  # Devolutiva do backup no Telegram (roda no container)
│   ├── telegram_config.env.example  # Credenciais do notify (copiar para telegram_config.env)
│   └── log/                # Logs dos scripts (gerado em runtime)
├── duplicati/
│   ├── config/             # Configuração/banco do Duplicati (gerado em runtime)
│   └── backups/            # Destino local dos backups (opcional)
└── filebrowser/
    ├── config/             # Configuração do File Browser
    ├── database/           # Banco do File Browser
    └── srv/
        └── restore/        # Pasta de restauração exposta na web
```

As pastas de runtime são ignoradas pelo Git (`.gitignore`) — o repositório
versiona apenas o template.

## Como usar em um novo servidor

1. **Clonar e configurar:**

   ```bash
   git clone <url-deste-repo> backup-stack && cd backup-stack
   cp .env.example .env
   ```

2. **Editar o `.env`:** hostname do servidor, `PUID/PGID` (verifique com `id`),
   ponto de montagem do share e segredos:

   ```bash
   openssl rand -base64 12   # DUPLICATI_WEB_PASSWORD
   openssl rand -base64 16   # DUPLICATI_SETTINGS_KEY
   ```

3. **Garantir a montagem do share no host** (exemplo com CIFS no `/etc/fstab`):

   ```
   //ip-do-servidor/share  /mnt/fileserver  cifs  credentials=/root/.smbcred,ro,_netdev  0  0
   ```

   > O bind usa `propagation: rslave`: se o share cair e for remontado no host,
   > o container enxerga a remontagem automaticamente, sem precisar de restart.

4. **Subir o stack:**

   ```bash
   docker compose up -d
   ```

5. **Acessar:**

   | Serviço      | URL                       | Credenciais                          |
   |--------------|---------------------------|--------------------------------------|
   | Duplicati    | `http://<host>:8900`      | senha do `.env`                      |
   | File Browser | `http://<host>:8081`      | `admin/admin` no 1º acesso — **troque** |

6. **Criar o job de backup no Duplicati:** origem `/fileserver`, destino
   `/backups` (ou remoto), agendamento e retenção conforme a necessidade.

7. **Configurar a verificação de montagens** (veja a seção abaixo).

## Verificação de montagens (`scripts/check-mounts.sh`)

Falha silenciosa clássica: o share cai, o Duplicati roda mesmo assim e gera um
backup "bem-sucedido" **vazio**. O script elimina esse risco verificando, antes
do horário do backup, se cada ponto de montagem está:

- **montado** (`mountpoint`) e **acessível** (com timeout, para detectar mount
  travado por I/O);
- com o **filesystem esperado** (`cifs`/`nfs4` — e não o disco local por baixo
  do ponto de montagem);
- **populado** com um mínimo de itens (sem depender de arquivo sentinela).

O que estiver caído é remontado automaticamente a partir do `/etc/fstab`
(3 tentativas), e um relatório formatado é enviado ao Telegram
(🟢 tudo ok / 🟡 recuperado / 🔴 falha — não faça backup).

**Configuração:**

1. Edite o array `MOUNTS` no topo do script com os seus pontos de montagem
   (cada um precisa ter entrada no `/etc/fstab`):

   ```bash
   MOUNTS=(
     "/mnt/fileserver/usuarios|cifs"
     "/mnt/fileserver/publico|cifs"
   )
   ```

2. Configure as credenciais do Telegram:

   ```bash
   cd scripts
   cp .telegram.example .telegram
   chmod 600 .telegram   # e preencha TG_BOT_TOKEN e TG_CHAT_ID
   ```

3. Agende no crontab do **root**, antes do horário do backup do Duplicati
   (ex.: verificação às 21:30 para backup às 22:00):

   ```cron
   30 21 * * * /caminho/do/repo/scripts/check-mounts.sh >/dev/null 2>&1
   ```

O log fica em `scripts/log/check-mounts.log`. O script usa lock
(`/var/lock/check-mounts.lock`) para nunca sobrepor execuções, e retorna
exit code `1` em falha — útil para encadear com outras automações.

## Devolutiva do backup (`scripts/notify-telegram.sh`)

Complemento do check-mounts: enquanto ele valida o **antes**, este script
reporta o **depois**. O Duplicati o executa ao final de cada job e envia um
relatório ao Telegram com resultado (✅ Sucesso / ⚠️ Alerta / ❌ Erro /
💥 Fatal), duração e estatísticas (arquivos adicionados, alterados,
excluídos, examinados — e o equivalente para restaurações).

Diferente do check-mounts (que roda no **host**, via cron), este roda
**dentro do container** do Duplicati — a pasta `./scripts` já é montada como
`/scripts` (somente leitura) no `docker-compose.yml`.

Baseado no projeto
[spupuz/duplicati-telegram-notifications](https://github.com/spupuz/duplicati-telegram-notifications),
com dois ajustes para uso em produção: o **auto-update foi removido** (o
script baixava e executava a versão mais recente direto do GitHub — as
versões aqui são controladas pelo próprio repositório) e a chamada ao
Telegram passou a **validar o certificado TLS** (removido o `curl -k`).

**Configuração:**

1. Crie o arquivo de credenciais:

   ```bash
   cd scripts
   cp telegram_config.env.example telegram_config.env
   chmod 600 telegram_config.env   # e preencha TELEGRAM_TOKEN e TELEGRAM_CHATID
   ```

2. Em cada job do Duplicati, em **Opções avançadas**, adicione:

   | Opção               | Valor                        |
   |---------------------|------------------------------|
   | `run-script-after`  | `/scripts/notify-telegram.sh` |
   | `run-script-before` | `/scripts/notify-telegram.sh` *(opcional — avisa também no início)* |

> Os dois scripts usam arquivos de credenciais separados (`.telegram` no host,
> `telegram_config.env` no container), então podem inclusive notificar chats
> diferentes — ex.: check-mounts para o grupo técnico e a devolutiva do backup
> para o grupo do cliente.

## Restauração

1. No Duplicati, escolha o backup e restaure para **`/backup-restore`**.
2. Os arquivos aparecem no File Browser em **`/srv/restore`**.
3. Após a entrega, limpe a pasta de restauração.

## Variante: Samba no mesmo host

Se o servidor de arquivos for um container Samba rodando neste mesmo host,
comente o bloco do bind `${FILESERVER_MOUNT}` no `docker-compose.yml` e
habilite o bloco comentado que aponta para `../samba/samba/shares`.

## Segurança

- **Nunca versione o `.env`** — ele contém a senha da web e a chave de
  criptografia (já está no `.gitignore`).
- O share entra no container **somente leitura**: o Duplicati não consegue
  alterar os arquivos de origem.
- Exponha as portas 8900/8081 apenas na rede interna, ou coloque um reverse
  proxy com HTTPS na frente.
