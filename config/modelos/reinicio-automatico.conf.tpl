# Gerado pelos scripts do Elo: se o serviço cair, o systemd sobe de novo, sem limite de tentativas.
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=3
