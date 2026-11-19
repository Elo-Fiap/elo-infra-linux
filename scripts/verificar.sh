#!/usr/bin/env bash
# verificar: confere a infraestrutura inteira e grava o resultado como evidência.
#   rede, DNS, serviços, aplicação pelo nome, monitor e logs.
# Critério da GS: "Funcionamento completo da proposta".
# Uso: sudo bash scripts/verificar.sh
# A saída fica em evidencias/verificacao-<data>.txt e os logs do momento em evidencias/logs-<data>/.

# shellcheck source=lib/comum.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/comum.sh"
gravar_evidencia "verificacao" "$@"
iniciar "verificar" "$@"

PROBLEMAS=0
# checar "descrição" comando...   Marca [ok] ou [FALHOU] sem parar o script.
checar() {
  local descricao="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    log "   [ok]     $descricao"
  else
    log "   [FALHOU] $descricao"
    PROBLEMAS=$((PROBLEMAS + 1))
  fi
}
mostrar() { sed 's/^/      | /'; }

descobrir_rede
URL_SAUDE="http://127.0.0.1:$APP_PORTA/health"
dns_diz() { [[ "$(dig +short +time=2 +tries=1 @127.0.0.1 "$1" A 2>/dev/null | tail -n1)" == "$IP_SERVIDOR" ]]; }
http_200() { [[ "$(codigo_http "$@")" == 200 ]]; }

# ---------------------------------------------------------------------------------------------------
passo "Máquina e rede"
info "sistema: $(. /etc/os-release && echo "$PRETTY_NAME"), kernel $(uname -r)"
info "hostname: $(hostname) (nome completo: $(hostname -f 2>/dev/null || hostname))"
info "placa $INTERFACE: $IP_SERVIDOR/$PREFIXO, saída ${GATEWAY:-não definida}"
checar "hostname é $NOME_HOST" test "$(hostname)" = "$NOME_HOST"
checar "a placa $INTERFACE tem o IP $IP_SERVIDOR" bash -c "ip -4 -o addr show dev '$INTERFACE' | grep -q ' $IP_SERVIDOR/'"
if command -v ufw >/dev/null; then
  ufw status 2>/dev/null | sed -n '1,10p' | mostrar || true
fi

# ---------------------------------------------------------------------------------------------------
passo "DNS (BIND9, zona $DOMINIO)"
for nome in "$DOMINIO" "www.$DOMINIO" "ns1.$DOMINIO" "api.$DOMINIO"; do
  checar "$nome resolve para $IP_SERVIDOR" dns_diz "$nome"
done
axfr_recusado() { dig +time=3 +tries=1 @127.0.0.1 "$DOMINIO" AXFR 2>&1 | grep -q 'Transfer failed'; }
checar "transferência de zona (AXFR) recusada" axfr_recusado
checar "zona válida (named-checkzone)" named-checkzone "$DOMINIO" "/etc/bind/db.$DOMINIO"
dig +noall +answer @127.0.0.1 "$DOMINIO" SOA 2>/dev/null | mostrar || true

# ---------------------------------------------------------------------------------------------------
passo "Serviços (systemd)"
printf '      | %-14s %-10s %-10s %s\n' "SERVIÇO" "ESTADO" "NO BOOT" "REINÍCIO AUTOMÁTICO"
for servico in $SERVICOS_VIGIADOS elo-monitor; do
  printf '      | %-14s %-10s %-10s %s\n' "$servico" \
    "$(systemctl is-active "$servico" 2>/dev/null || true)" \
    "$(systemctl is-enabled "$servico" 2>/dev/null || true)" \
    "$(systemctl show -p Restart --value "$servico" 2>/dev/null || true)"
  checar "$servico ativo" systemctl is-active --quiet "$servico"
  checar "$servico ligado na inicialização" systemctl is-enabled --quiet "$servico"
done

# ---------------------------------------------------------------------------------------------------
passo "Aplicação (API do Elo atrás do Apache)"
info "versão publicada: $(cat "$DIR_APP/VERSAO" 2>/dev/null || echo desconhecida), rodando como $(systemctl show -p User --value elo-api 2>/dev/null)"
checar "API responde 200 em $URL_SAUDE" http_200 "$URL_SAUDE"
IP_DO_NOME="$(dig +short +time=2 +tries=1 @127.0.0.1 "www.$DOMINIO" A 2>/dev/null | tail -n1 || true)"
for caminho in / /health /regua /risco-cidadao.html /swagger/index.html; do
  checar "http://www.$DOMINIO$caminho responde 200 (nome resolvido pelo DNS da VM)" \
    http_200 "http://www.$DOMINIO$caminho" --resolve "www.$DOMINIO:80:${IP_DO_NOME:-127.0.0.1}"
done
porta_so_local() { ss -ltnH "sport = :$APP_PORTA" | awk '{print $4}' | grep -q '^127\.0\.0\.1:'; }
checar "a API só escuta em 127.0.0.1:$APP_PORTA" porta_so_local
BANNER="$(curl -sI --max-time 4 -H "Host: www.$DOMINIO" http://127.0.0.1/ | tr -d '\r' | sed -n 's/^Server: //Ip' || true)"
info "cabeçalho Server que o cliente recebe: ${BANNER:-nenhum}"
checar "o Apache não informa a versão" test "$BANNER" = "Apache"

# ---------------------------------------------------------------------------------------------------
passo "Monitoramento e logs"
leitura_recente() { [[ -n "$(find "$DIR_LOG/monitor.log" -newermt "$((INTERVALO_SEGUNDOS * 3)) seconds ago" 2>/dev/null)" ]]; }
checar "o monitor escreveu leitura nos últimos $((INTERVALO_SEGUNDOS * 3))s" leitura_recente
for arquivo in provisionamento.log auditoria.log monitor.log alertas.log; do
  checar "$DIR_LOG/$arquivo existe e tem conteúdo" test -s "$DIR_LOG/$arquivo"
done
info "últimas leituras do monitor:"
tail -n 3 "$DIR_LOG/monitor.log" 2>/dev/null | mostrar || true
info "últimos alertas e ações:"
tail -n 6 "$DIR_LOG/alertas.log" 2>/dev/null | mostrar || true
info "últimas linhas da auditoria:"
tail -n 6 "$DIR_LOG/auditoria.log" 2>/dev/null | mostrar || true

# ---------------------------------------------------------------------------------------------------
passo "Guardar os logs como evidência"
DESTINO="$RAIZ/evidencias/logs-$(date +%Y%m%d-%H%M%S)"
install -d "$DESTINO"
for arquivo in provisionamento.log auditoria.log alertas.log; do
  if [[ -f $DIR_LOG/$arquivo ]]; then cp "$DIR_LOG/$arquivo" "$DESTINO/"; fi
done
tail -n 200 "$DIR_LOG/monitor.log" >"$DESTINO/monitor.log" 2>/dev/null || true
journalctl -u elo-api -u elo-monitor -u named -u apache2 --since "-2 hours" --no-pager -o short-iso 2>/dev/null |
  tail -n 300 >"$DESTINO/journal-servicos.txt" || true
if [[ -n ${SUDO_USER:-} ]]; then chown -R "$SUDO_USER": "$RAIZ/evidencias" 2>/dev/null || true; fi
ok "logs copiados para ${DESTINO#"$RAIZ"/}"

passo "Resultado"
if ((PROBLEMAS > 0)); then
  falha "$PROBLEMAS conferência(s) falharam (as linhas marcadas com [FALHOU] acima)"
fi
ok "tudo conferido: http://www.$DOMINIO está no ar; nos clientes da rede, use $IP_SERVIDOR como servidor DNS"
