#!/usr/bin/env bash
# 01-infra: prepara a rede da VM para receber a aplicação.
#   hostname, IP fixo, servidor DNS (BIND9) com a zona do projeto, resolução local e firewall.
# Critério da GS: "Script de provisionamento de configurações de infra (redes, DNS, IP)".
# Uso: sudo bash scripts/01-infra.sh
# Pode rodar quantas vezes quiser: só muda o que estiver diferente.

# shellcheck source=lib/comum.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/comum.sh"
iniciar "01-infra" "$@"

# ---------------------------------------------------------------------------------------------------
passo "Conferir o sistema e descobrir a rede"
SISTEMA="$(. /etc/os-release && echo "$PRETTY_NAME")"
info "sistema: $SISTEMA, kernel $(uname -r)"
[[ "$(. /etc/os-release && echo "$ID")" == ubuntu ]] || aviso "os scripts foram escritos para Ubuntu 24.04; aqui é $SISTEMA"
instalar iproute2
descobrir_rede
info "placa $INTERFACE, IP $IP_SERVIDOR/$PREFIXO, saída ${GATEWAY:-não definida}"

# ---------------------------------------------------------------------------------------------------
passo "Hostname: $NOME_HOST.$DOMINIO"
if [[ "$(hostname)" != "$NOME_HOST" ]]; then
  ANTES="$(hostname)"
  if command -v hostnamectl >/dev/null && hostnamectl set-hostname "$NOME_HOST" >>"$LOG_EXECUCAO" 2>&1; then
    :
  else
    echo "$NOME_HOST" >/etc/hostname
    hostname "$NOME_HOST"
  fi
  ok "hostname trocado de $ANTES para $NOME_HOST"
  auditar hostname "de $ANTES para $NOME_HOST"
else
  ok "hostname já é $NOME_HOST"
fi
# /etc/hosts: o nome completo aponta para a própria máquina. O arquivo é regravado no lugar (sem mv).
LINHA_HOSTS="$(printf '127.0.1.1\t%s.%s %s\t# elo' "$NOME_HOST" "$DOMINIO" "$NOME_HOST")"
if ! grep -qxF "$LINHA_HOSTS" /etc/hosts; then
  TMP="$(mktemp)"
  grep -v -E '# elo$|^127\.0\.1\.1[[:space:]]' /etc/hosts >"$TMP" || true
  printf '%s\n' "$LINHA_HOSTS" >>"$TMP"
  cat "$TMP" >/etc/hosts
  rm -f "$TMP"
  ok "/etc/hosts atualizado"
  auditar arquivo "escrito /etc/hosts"
else
  ok "/etc/hosts já está certo"
fi

# ---------------------------------------------------------------------------------------------------
passo "IP fixo: $IP_SERVIDOR/$PREFIXO na placa $INTERFACE"

tem_ip_e_rota() {
  ip -4 -o addr show dev "$INTERFACE" | grep -q " $IP_SERVIDOR/$PREFIXO " &&
    { [[ -z $GATEWAY ]] || ip -4 route show default | grep -q "via $GATEWAY "; }
}

ip_fixo_pelo_networkmanager() {
  local conexao metodo enderecos saida dns
  conexao="$(nmcli -g GENERAL.CONNECTION device show "$INTERFACE" 2>/dev/null | head -n1)"
  if [[ -z $conexao ]]; then
    aviso "o NetworkManager não tem conexão ativa na placa $INTERFACE; o IP não foi fixado"
    return 0
  fi
  metodo="$(nmcli -g ipv4.method connection show "$conexao")"
  enderecos="$(nmcli -g ipv4.addresses connection show "$conexao")"
  saida="$(nmcli -g ipv4.gateway connection show "$conexao")"
  if [[ $metodo == manual && $enderecos == "$IP_SERVIDOR/$PREFIXO" ]]; then
    ok "o IP já está fixo na conexão \"$conexao\""
    return 0
  fi
  # Com IP manual os servidores DNS do DHCP somem: guardamos os que estão em uso.
  dns="$(nmcli -g IP4.DNS device show "$INTERFACE" 2>/dev/null | tr '|' '\n' | xargs | tr ' ' ',' || true)"
  [[ -n $dns ]] || dns="${DNS_EXTERNOS// /,}"
  info "conexão \"$conexao\": de \"$metodo ${enderecos:-sem endereço}\" para manual $IP_SERVIDOR/$PREFIXO"
  executar "gravar o IP fixo na conexão" nmcli connection modify "$conexao" \
    ipv4.method manual ipv4.addresses "$IP_SERVIDOR/$PREFIXO" ipv4.gateway "$GATEWAY" ipv4.dns "$dns"
  nmcli connection up "$conexao" >>"$LOG_EXECUCAO" 2>&1 || true
  sleep 2
  if tem_ip_e_rota; then
    ok "placa reativada com o IP fixo"
    auditar rede "IP fixo $IP_SERVIDOR/$PREFIXO via $GATEWAY na conexão $conexao"
    return 0
  fi
  log "   ERRO: a placa não ficou com o IP e a rota esperados; voltando a conexão ao que era"
  nmcli connection modify "$conexao" ipv4.method "$metodo" ipv4.addresses "$enderecos" ipv4.gateway "$saida" >>"$LOG_EXECUCAO" 2>&1 || true
  nmcli connection up "$conexao" >>"$LOG_EXECUCAO" 2>&1 || true
  falha "não consegui fixar o IP pelo NetworkManager (a conexão voltou ao que era)"
}

ip_fixo_pelo_netplan() {
  local arquivo=/etc/netplan/60-elo.yaml dns
  dns="$(resolvectl dns "$INTERFACE" 2>/dev/null | cut -d: -f2- | xargs | tr ' ' ',' || true)"
  [[ -n $dns ]] || dns="${DNS_EXTERNOS// /,}"
  DNS_DA_PLACA="${dns//,/, }"
  renderizar netplan-ip-fixo.yaml.tpl "$arquivo" 600
  if [[ $MUDOU == nao ]] && tem_ip_e_rota; then
    ok "o IP já está fixo pelo netplan"
    return 0
  fi
  if ! netplan generate >>"$LOG_EXECUCAO" 2>&1; then
    rm -f "$arquivo"
    falha "o netplan recusou a configuração gerada (arquivo removido; veja o log)"
  fi
  if netplan apply >>"$LOG_EXECUCAO" 2>&1 && sleep 2 && tem_ip_e_rota; then
    ok "netplan aplicado: placa com o IP fixo"
    auditar rede "IP fixo $IP_SERVIDOR/$PREFIXO via $GATEWAY pelo netplan"
  else
    rm -f "$arquivo"
    netplan apply >>"$LOG_EXECUCAO" 2>&1 || true
    falha "o netplan não deixou a placa com o IP e a rota esperados (configuração desfeita; veja o log)"
  fi
}

if [[ $CONFIGURAR_IP_FIXO != sim ]]; then
  info "CONFIGURAR_IP_FIXO=$CONFIGURAR_IP_FIXO: o endereço da placa não foi alterado"
elif [[ -z $GATEWAY ]]; then
  aviso "a VM não tem rota padrão; o IP não foi fixado"
elif systemctl is-active --quiet NetworkManager 2>/dev/null && command -v nmcli >/dev/null; then
  info "quem cuida da rede aqui é o NetworkManager"
  ip_fixo_pelo_networkmanager
elif command -v netplan >/dev/null; then
  info "quem cuida da rede aqui é o netplan (systemd-networkd)"
  ip_fixo_pelo_netplan
else
  aviso "sem NetworkManager nem netplan nesta máquina; o IP não foi fixado"
fi

# ---------------------------------------------------------------------------------------------------
passo "Servidor DNS (BIND9) com a zona $DOMINIO"
instalar bind9 bind9-utils bind9-dnsutils
ZONA="/etc/bind/db.$DOMINIO"
PRECISA_RECARREGAR="nao"

ENCAMINHADORES=""
for servidor in $DNS_EXTERNOS; do ENCAMINHADORES+="$servidor; "; done
renderizar named.conf.options.tpl /etc/bind/named.conf.options
[[ $MUDOU == sim ]] && PRECISA_RECARREGAR="sim"
renderizar named.conf.local.tpl /etc/bind/named.conf.local
[[ $MUDOU == sim ]] && PRECISA_RECARREGAR="sim"

# O serial só sobe quando o conteúdo da zona muda.
HOJE="$(date +%Y%m%d)"
SERIAL="$(awk 'tolower($0) ~ /; *serial/ {print $1; exit}' "$ZONA" 2>/dev/null || true)"
[[ $SERIAL =~ ^[0-9]{10}$ ]] || SERIAL="${HOJE}00"
SERIAL_ATUAL="$SERIAL"
PROVA="$(mktemp)"
montar zona.db.tpl >"$PROVA"
if [[ ! -f $ZONA ]] || ! cmp -s "$PROVA" "$ZONA"; then
  if [[ ${SERIAL_ATUAL:0:8} == "$HOJE" ]]; then
    SERIAL="$(printf '%s%02d' "$HOJE" $((10#${SERIAL_ATUAL:8:2} + 1)))"
  else
    SERIAL="${HOJE}01"
  fi
  renderizar zona.db.tpl "$ZONA"
  PRECISA_RECARREGAR="sim"
  info "serial da zona: $SERIAL"
else
  info "zona sem mudança (serial $SERIAL_ATUAL)"
fi
rm -f "$PROVA"

executar "validar a configuração (named-checkconf)" named-checkconf
executar "validar a zona (named-checkzone)" named-checkzone "$DOMINIO" "$ZONA"
renderizar reinicio-automatico.conf.tpl /etc/systemd/system/named.service.d/elo-reinicio.conf
[[ $MUDOU == sim ]] && systemctl daemon-reload
executar "ligar o BIND na inicialização" systemctl enable named
if [[ $PRECISA_RECARREGAR == sim ]] || ! systemctl is-active --quiet named; then
  executar "reiniciar o BIND" systemctl restart named
  auditar servico "named reiniciado"
else
  ok "BIND já estava rodando com esta configuração"
fi
dns_responde() { [[ "$(dig +short +time=2 +tries=1 @127.0.0.1 "www.$DOMINIO" A | tail -n1)" == "$IP_SERVIDOR" ]]; }
esperar "o BIND responder por www.$DOMINIO" 30 dns_responde

# ---------------------------------------------------------------------------------------------------
passo "Resolução de nomes na própria VM"
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  renderizar resolved-elo.conf.tpl /etc/systemd/resolved.conf.d/elo.conf
  if [[ $MUDOU == sim ]]; then
    executar "reiniciar o systemd-resolved" systemctl restart systemd-resolved
  fi
  if ! esperar "a VM resolver www.$DOMINIO pelo próprio DNS" 15 resolvectl query "www.$DOMINIO"; then
    aviso "a VM ainda não resolve www.$DOMINIO pelo resolvedor do sistema (o BIND responde em 127.0.0.1)"
  fi
else
  info "systemd-resolved não está ativo: a resolução local não foi alterada"
fi

# ---------------------------------------------------------------------------------------------------
passo "Firewall (UFW): só SSH, DNS e HTTP entram"
if [[ $CONFIGURAR_FIREWALL != sim ]]; then
  info "CONFIGURAR_FIREWALL=$CONFIGURAR_FIREWALL: o firewall não foi alterado"
else
  instalar ufw
  if ufw allow 22/tcp comment 'SSH' >>"$LOG_EXECUCAO" 2>&1 &&
    ufw allow 53 comment 'DNS (BIND9)' >>"$LOG_EXECUCAO" 2>&1 &&
    ufw allow 80/tcp comment 'HTTP (Apache para a API do Elo)' >>"$LOG_EXECUCAO" 2>&1 &&
    ufw --force enable >>"$LOG_EXECUCAO" 2>&1; then
    ok "regras gravadas e firewall ligado"
    ufw status 2>/dev/null | sed -n '1,12p' | sed 's/^/      | /' || true
    auditar firewall "UFW ligado: 22/tcp, 53 e 80/tcp liberados"
  else
    aviso "não consegui ligar o UFW nesta máquina (veja o log); o resto do provisionamento continua"
  fi
fi

# ---------------------------------------------------------------------------------------------------
passo "Conferir as respostas do DNS"
for nome in "$DOMINIO" "www.$DOMINIO" "ns1.$DOMINIO" "api.$DOMINIO"; do
  RESPOSTA="$(dig +short +time=3 +tries=2 @127.0.0.1 "$nome" A 2>/dev/null | tail -n1 || true)"
  [[ $RESPOSTA == "$IP_SERVIDOR" ]] || falha "o DNS respondeu \"$RESPOSTA\" para $nome (esperado $IP_SERVIDOR)"
  ok "$nome -> $RESPOSTA"
done
if dig +time=3 +tries=1 @127.0.0.1 "$DOMINIO" AXFR 2>&1 | grep -q 'Transfer failed'; then
  ok "transferência de zona (AXFR) recusada, como configurado"
else
  aviso "a transferência de zona não foi recusada"
fi
if [[ -n "$(dig +short +time=3 +tries=1 @127.0.0.1 archive.ubuntu.com A 2>/dev/null)" ]]; then
  ok "nomes de fora resolvem pelos encaminhadores ($DNS_EXTERNOS)"
else
  aviso "o BIND não resolveu um nome de fora pelos encaminhadores ($DNS_EXTERNOS); a zona $DOMINIO funciona, mas os clientes que usarem este DNS podem não navegar"
fi
info "nos clientes da rede, o servidor DNS deve ser $IP_SERVIDOR"
