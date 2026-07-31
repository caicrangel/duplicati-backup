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
2. O Duplicati executa os jobs de backup (origem: `/fileserver`; destino:
   `/backups` local ou um destino remoto — S3, SFTP, Google Drive etc.).
3. Quando é preciso restaurar algo, restaura-se para `/backup-restore`, que é a
   mesma pasta servida pelo File Browser (`/srv/restore`) — o usuário baixa os
   arquivos pelo navegador, sem acesso ao servidor.

## Estrutura do repositório

```
.
├── docker-compose.yml      # Definição dos serviços
├── .env.example            # Modelo de variáveis (copiar para .env)
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
