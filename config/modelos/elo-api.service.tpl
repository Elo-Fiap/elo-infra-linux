# Gerado por scripts/02-aplicacao.sh (Elo).
[Unit]
Description=Elo - API do bairro (aplicacao CitizenTech hospedada)
Documentation=https://github.com/Elo-Fiap/elo-api-csharp
After=network-online.target named.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=@@APP_USUARIO@@
Group=@@APP_USUARIO@@
WorkingDirectory=@@DIR_APP@@/app
EnvironmentFile=@@DIR_CONFIG@@/elo-api.env
ExecStart=@@DOTNET_BIN@@ @@DIR_APP@@/app/Elo.Api.dll
Restart=always
RestartSec=3
SyslogIdentifier=elo-api

# A aplicação só escreve na pasta de dados.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=@@DIR_DADOS@@

[Install]
WantedBy=multi-user.target
