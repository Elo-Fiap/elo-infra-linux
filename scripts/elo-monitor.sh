#!/usr/bin/env bash
# elo-monitor: acompanha CPU, memória, disco e os serviços do Elo.
#   - a cada ciclo escreve uma linha de leitura em /var/log/elo/monitor.log;
#   - quando um limite é passado, escreve um ALERTA em /var/log/elo/alertas.log e no journal;
#   - quando volta ao normal, escreve NORMALIZADO;
#   - serviço parado: alerta e (se configurado) manda o systemd subir de novo, registrando a AÇÃO.
# Critério da GS: "Script de monitoramento de infra que gera alertas de consumo de CPU, Disco e Memória".
# Roda como serviço (elo-monitor.service, instalado pelo scripts/03-monitoramento.sh).
# Uso manual:  elo-monitor --uma-vez [--sem-acao]     (um ciclo só, mostrando na tela)

set -uo pipefail # sem "-e": uma medição que falha não pode derrubar o monitor

# ---------- Configuração (os valores abaixo valem se /etc/elo/monitor.conf não existir) ----------
INTERVALO_SEGUNDOS=15
LIMITE_CPU=80
LIMITE_MEMORIA=80
LIMITE_DISCO=85
REPETIR_ALERTA_MINUTOS=5
SERVICOS_VIGIADOS="named apache2 elo-api"
REINICIAR_SERVICO_PARADO=sim
DISCOS_VIGIADOS="/"
URL_SAUDE="http://127.0.0.1:5080/health"
DIR_LOG="/var/log/elo"
CONF="${ELO_MONITOR_CONF:-/etc/elo/monitor.conf}"
# shellcheck source=/dev/null
[[ -r $CONF ]] && source "$CONF"
# Limites trocados só para uma execução (usado pelo teste de falha).
LIMITE_CPU="${ELO_LIMITE_CPU:-$LIMITE_CPU}"
LIMITE_MEMORIA="${ELO_LIMITE_MEMORIA:-$LIMITE_MEMORIA}"
LIMITE_DISCO="${ELO_LIMITE_DISCO:-$LIMITE_DISCO}"

UMA_VEZ="nao"
SEM_ACAO="nao"
for argumento in "$@"; do
  case "$argumento" in
    --uma-vez) UMA_VEZ="sim" ;;
    --sem-acao) SEM_ACAO="sim" ;;
    -h | --ajuda)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "argumento desconhecido: $argumento" >&2
      exit 2
      ;;
  esac
done

LOG_LEITURAS="$DIR_LOG/monitor.log"
LOG_ALERTAS="$DIR_LOG/alertas.log"
MAQUINA="$(hostname)"
declare -A ESTADO=()      # chave -> normal | alerta
declare -A ULTIMO_AVISO=() # chave -> segundo em que o último alerta saiu
CPU_TOTAL_ANTES=0
CPU_OCIOSO_ANTES=0

agora() { date '+%Y-%m-%dT%H:%M:%S%z'; }

preparar_logs() {
  [[ -d $DIR_LOG ]] || install -d -m 750 -o root -g adm "$DIR_LOG" 2>/dev/null || mkdir -p "$DIR_LOG"
  touch "$LOG_LEITURAS" "$LOG_ALERTAS" 2>/dev/null
  chown root:adm "$LOG_LEITURAS" "$LOG_ALERTAS" 2>/dev/null
  chmod 640 "$LOG_LEITURAS" "$LOG_ALERTAS" 2>/dev/null
}

leitura() {
  printf '%s host=%s %s\n' "$(agora)" "$MAQUINA" "$*" >>"$LOG_LEITURAS"
  [[ $UMA_VEZ == sim ]] && printf 'leitura: %s\n' "$*"
  return 0
}

# emitir <ALERTA|NORMALIZADO|ACAO|INFO> <chave> <mensagem>
emitir() {
  local tipo="$1" chave="$2" mensagem="$3" nivel=4 linha # 4 = aviso, 5 = informação
  [[ $tipo == NORMALIZADO || $tipo == INFO ]] && nivel=5
  linha="$tipo $chave: $mensagem"
  printf '%s host=%s %s\n' "$(agora)" "$MAQUINA" "$linha" >>"$LOG_ALERTAS"
  if [[ -n ${JOURNAL_STREAM:-} ]]; then
    printf '<%s>%s\n' "$nivel" "$linha" # como serviço: a saída já cai no journal, com o nível na frente
  else
    logger -t elo-monitor -p "daemon.$([[ $nivel == 4 ]] && echo warning || echo notice)" -- "$linha" 2>/dev/null
    printf '%s\n' "$linha"
  fi
}

# avaliar <chave> <valor> <limite> <o que é>   Compara e cuida da passagem normal <-> alerta.
avaliar() {
  local chave="$1" valor="$2" limite="$3" descricao="$4" antes="${ESTADO[$1]:-normal}" ultimo="${ULTIMO_AVISO[$1]:-0}"
  if ((valor >= limite)); then
    if [[ $antes != alerta ]] || ((SECONDS - ultimo >= REPETIR_ALERTA_MINUTOS * 60)); then
      emitir ALERTA "$chave" "$descricao em ${valor}% (limite ${limite}%)"
      ULTIMO_AVISO[$chave]=$SECONDS
    fi
    ESTADO[$chave]="alerta"
  else
    [[ $antes == alerta ]] && emitir NORMALIZADO "$chave" "$descricao voltou para ${valor}% (limite ${limite}%)"
    ESTADO[$chave]="normal"
  fi
}

# Uso de CPU (%) desde a medição anterior, pelo /proc/stat. Na primeira vez mede por 1 segundo.
uso_de_cpu() {
  local usuario nice sistema ocioso espera irq softirq roubo total parado
  if ((CPU_TOTAL_ANTES == 0)); then
    read -r _ usuario nice sistema ocioso espera irq softirq roubo _ </proc/stat
    CPU_TOTAL_ANTES=$((usuario + nice + sistema + ocioso + espera + irq + softirq + roubo))
    CPU_OCIOSO_ANTES=$((ocioso + espera))
    sleep 1
  fi
  read -r _ usuario nice sistema ocioso espera irq softirq roubo _ </proc/stat
  total=$((usuario + nice + sistema + ocioso + espera + irq + softirq + roubo))
  parado=$((ocioso + espera))
  local d_total=$((total - CPU_TOTAL_ANTES)) d_parado=$((parado - CPU_OCIOSO_ANTES))
  CPU_TOTAL_ANTES=$total
  CPU_OCIOSO_ANTES=$parado
  if ((d_total > 0)); then
    USO_CPU=$(((100 * (d_total - d_parado)) / d_total))
  else
    USO_CPU=0
  fi
}

uso_de_memoria() {
  USO_MEMORIA="$(awk '/^MemTotal:/ {t = $2} /^MemAvailable:/ {d = $2} END {if (t > 0) printf "%d", (100 * (t - d)) / t; else print 0}' /proc/meminfo)"
}

ciclo() {
  local resumo="" pasta sistema uso servico situacao codigo vistos=" "

  uso_de_cpu
  avaliar cpu "$USO_CPU" "$LIMITE_CPU" "uso de CPU"
  uso_de_memoria
  avaliar memoria "$USO_MEMORIA" "$LIMITE_MEMORIA" "uso de memória"
  resumo="cpu=${USO_CPU}% memoria=${USO_MEMORIA}%"

  # Disco: uma medição por sistema de arquivos, mesmo que duas pastas vigiadas fiquem no mesmo.
  for pasta in $DISCOS_VIGIADOS; do
    [[ -d $pasta ]] || continue
    read -r sistema uso < <(df -P "$pasta" 2>/dev/null | awk 'NR == 2 {gsub("%", "", $5); print $1, $5}')
    [[ -n ${uso:-} ]] || continue
    [[ $vistos == *" $sistema "* ]] && continue
    vistos+="$sistema "
    avaliar "disco:$pasta" "$uso" "$LIMITE_DISCO" "uso do disco em $pasta"
    resumo+=" disco[$pasta]=${uso}%"
  done

  # Serviços: parado ou em falha gera alerta e, se configurado, um pedido de reinício.
  resumo+=" servicos="
  for servico in $SERVICOS_VIGIADOS; do
    if ! systemctl cat "$servico" >/dev/null 2>&1; then
      resumo+="$servico:nao-instalado,"
      continue
    fi
    situacao="$(systemctl is-active "$servico" 2>/dev/null)"
    resumo+="$servico:$situacao,"
    case "$situacao" in
      active)
        if [[ ${ESTADO[servico:$servico]:-normal} == alerta ]]; then
          emitir NORMALIZADO "servico:$servico" "o serviço voltou a rodar"
        fi
        ESTADO[servico:$servico]="normal"
        ;;
      activating | deactivating | reloading) ;; # em transição: o systemd já está cuidando
      *)
        emitir ALERTA "servico:$servico" "o serviço está $situacao"
        ESTADO[servico:$servico]="alerta"
        if [[ $REINICIAR_SERVICO_PARADO == sim && $SEM_ACAO == nao ]]; then
          if systemctl restart "$servico" >/dev/null 2>&1; then
            emitir ACAO "servico:$servico" "reinício pedido ao systemd: aceito"
          else
            emitir ACAO "servico:$servico" "reinício pedido ao systemd: FALHOU"
          fi
        fi
        ;;
    esac
  done
  resumo="${resumo%,}"

  # Saúde da aplicação: a rota /health da API.
  if command -v curl >/dev/null; then
    codigo="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$URL_SAUDE" 2>/dev/null)"
    resumo+=" saude_http=${codigo:-000}"
    if [[ $codigo == 200 ]]; then
      [[ ${ESTADO[saude]:-normal} == alerta ]] && emitir NORMALIZADO saude "a aplicação voltou a responder 200 em /health"
      ESTADO[saude]="normal"
    elif systemctl cat elo-api >/dev/null 2>&1; then
      if [[ ${ESTADO[saude]:-normal} != alerta ]] || ((SECONDS - ${ULTIMO_AVISO[saude]:-0} >= REPETIR_ALERTA_MINUTOS * 60)); then
        emitir ALERTA saude "a aplicação respondeu ${codigo:-000} em $URL_SAUDE"
        ULTIMO_AVISO[saude]=$SECONDS
      fi
      ESTADO[saude]="alerta"
    fi
  fi

  leitura "$resumo"
}

encerrar() {
  emitir INFO monitor "encerrado (pid $$)"
  exit 0
}

preparar_logs
if [[ $UMA_VEZ == sim ]]; then
  ciclo
  exit 0
fi

trap encerrar TERM INT
emitir INFO monitor "iniciado (pid $$): a cada ${INTERVALO_SEGUNDOS}s; limites CPU ${LIMITE_CPU}%, memória ${LIMITE_MEMORIA}%, disco ${LIMITE_DISCO}%; serviços: $SERVICOS_VIGIADOS"
while :; do
  preparar_logs # se alguém apagar a pasta de logs, o monitor recria e continua
  ciclo
  sleep "$INTERVALO_SEGUNDOS" &
  wait $! # o "wait" deixa o sinal de parada ser atendido na hora
done
