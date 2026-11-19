# Gerado por scripts/03-monitoramento.sh (Elo). Rodízio semanal dos logs, 8 semanas guardadas.
@@DIR_LOG@@/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 640 root adm
}
