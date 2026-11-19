#!/usr/bin/env bash
# 03-monitoramento: instala o monitor do Elo como serviço do systemd e o rodízio dos logs.
# Critérios da GS: "Configuração de monitoramento como serviço tolerante a falhas" e
#                  "Logs de auditoria e execução dos scripts criados".
# Uso: sudo bash scripts/03-monitoramento.sh

# shellcheck source=lib/comum.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/comum.sh"
iniciar "03-monitoramento" "$@"

# ---------------------------------------------------------------------------------------------------
passo "Instalar o monitor em /usr/local/bin/elo-monitor"
instalar curl logrotate
PRECISA_REINICIAR="nao"
if ! cmp -s "$RAIZ/scripts/elo-monitor.sh" /usr/local/bin/elo-monitor; then
  install -m 755 -o root -g root "$RAIZ/scripts/elo-monitor.sh" /usr/local/bin/elo-monitor
  ok "monitor copiado"
  auditar arquivo "escrito /usr/local/bin/elo-monitor"
  PRECISA_REINICIAR="sim"
else
  ok "o monitor instalado já é esta versão"
fi

# ---------------------------------------------------------------------------------------------------
passo "Limites do monitor ($DIR_CONFIG/monitor.conf)"
install -d -m 750 "$DIR_CONFIG"
renderizar monitor.conf.tpl "$DIR_CONFIG/monitor.conf" 644
[[ $MUDOU == sim ]] && PRECISA_REINICIAR="sim"
info "a cada ${INTERVALO_SEGUNDOS}s; alerta com CPU >= ${LIMITE_CPU}%, memória >= ${LIMITE_MEMORIA}%, disco >= ${LIMITE_DISCO}%"
info "serviços vigiados: $SERVICOS_VIGIADOS (reinício automático: $REINICIAR_SERVICO_PARADO)"

# ---------------------------------------------------------------------------------------------------
passo "Monitor como serviço tolerante a falhas (systemd: elo-monitor.service)"
renderizar elo-monitor.service.tpl /etc/systemd/system/elo-monitor.service
if [[ $MUDOU == sim ]]; then
  systemctl daemon-reload
  PRECISA_REINICIAR="sim"
fi
executar "ligar o monitor na inicialização" systemctl enable elo-monitor
if [[ $PRECISA_REINICIAR == sim ]] || ! systemctl is-active --quiet elo-monitor; then
  executar "subir o monitor" systemctl restart elo-monitor
  auditar servico "elo-monitor reiniciado"
else
  ok "o monitor já estava rodando com esta configuração"
fi
info "Restart=always e sem limite de tentativas: se o processo morrer, o systemd sobe de novo em 5s"

# ---------------------------------------------------------------------------------------------------
passo "Rodízio dos logs ($DIR_LOG)"
renderizar logrotate-elo.tpl /etc/logrotate.d/elo 644
executar "validar a regra do logrotate" logrotate --debug /etc/logrotate.d/elo

# ---------------------------------------------------------------------------------------------------
passo "Conferir o monitor"
esperar "o serviço elo-monitor ficar ativo" 20 systemctl is-active --quiet elo-monitor
tem_leitura() { [[ -s $DIR_LOG/monitor.log ]]; }
esperar "a primeira leitura aparecer em $DIR_LOG/monitor.log" $((INTERVALO_SEGUNDOS + 15)) tem_leitura
info "última leitura: $(tail -n1 "$DIR_LOG/monitor.log")"
info "logs: $DIR_LOG/monitor.log (leituras), $DIR_LOG/alertas.log (alertas e ações),"
info "      $DIR_LOG/provisionamento.log (execução dos scripts) e $DIR_LOG/auditoria.log (quem fez o quê)"
