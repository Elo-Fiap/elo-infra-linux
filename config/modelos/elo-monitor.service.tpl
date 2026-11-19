# Gerado por scripts/03-monitoramento.sh (Elo).
[Unit]
Description=Elo - monitor de infraestrutura (CPU, memoria, disco e servicos)
After=network.target
# Sem limite de tentativas: o systemd nunca desiste de subir o monitor.
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/local/bin/elo-monitor
Restart=always
RestartSec=5
SyslogIdentifier=elo-monitor

[Install]
WantedBy=multi-user.target
