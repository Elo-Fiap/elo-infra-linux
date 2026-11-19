#!/usr/bin/env bash
# teste-de-falha: derruba de propósito cada peça e mostra a infraestrutura reagindo sozinha.
#   1. a aplicação é morta à força            -> o systemd sobe de novo
#   2. o monitor é morto à força              -> o systemd sobe de novo
#   3. o servidor web é parado                -> o monitor alerta e manda subir
#   4. o servidor DNS é parado                -> o monitor alerta e manda subir
#   5. a CPU fica ocupada                     -> o monitor alerta e depois avisa que normalizou
#   6. limites de memória e disco passados    -> o monitor alerta (com limite de teste de 1%)
# Pilar da GS: "Teste de falha".
# Uso: sudo bash scripts/teste-de-falha.sh            (todos os cenários)
#      sudo bash scripts/teste-de-falha.sh 1 3        (só os cenários 1 e 3)
# A saída da tela fica gravada em evidencias/teste-de-falha-<data>.txt.

# shellcheck source=lib/comum.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/comum.sh"
gravar_evidencia "teste-de-falha" "$@"
iniciar "teste-de-falha" "$@"

URL_SAUDE="http://127.0.0.1:$APP_PORTA/health"
ALERTAS="$DIR_LOG/alertas.log"
ESPERA_DO_MONITOR=$((INTERVALO_SEGUNDOS * 3 + 20)) # tempo para o monitor passar por dois ciclos completos
RESULTADOS=()
FALHAS=0
CARGAS=()

app_saudavel() { [[ "$(codigo_http "$URL_SAUDE")" == 200 ]]; }
site_no_ar() { [[ "$(codigo_http http://127.0.0.1/health -H "Host: www.$DOMINIO")" == 200 ]]; }
dns_no_ar() { [[ -n "$(dig +short +time=2 +tries=1 @127.0.0.1 "www.$DOMINIO" A 2>/dev/null)" ]]; }
linhas_de_alerta() { wc -l <"$ALERTAS" 2>/dev/null || echo 0; }
# Mostra o que o monitor escreveu em alertas.log desde a linha informada.
mostrar_alertas_desde() { tail -n "+$(($1 + 1))" "$ALERTAS" 2>/dev/null | sed 's/^/      | /' || true; }
alerta_novo() { tail -n "+$(($1 + 1))" "$ALERTAS" 2>/dev/null | grep -q "$2"; }

registrar() { # registrar <cenário> <passou|falhou> <detalhe>
  RESULTADOS+=("$1|$2|$3")
  [[ $2 == passou ]] || FALHAS=$((FALHAS + 1))
  auditar teste "$1: $2 ($3)"
}

parar_cargas() {
  local pid
  for pid in "${CARGAS[@]:-}"; do
    [[ -n $pid ]] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  CARGAS=()
  return 0
}
trap 'codigo_final=$?; parar_cargas; _ao_sair "$codigo_final"' EXIT

# ---------------------------------------------------------------------------------------------------
cenario_1() {
  local nome="1. Aplicação morta à força" pid antes depois inicio
  passo "Cenário 1: a aplicação é morta à força (kill -9)"
  if ! app_saudavel; then
    registrar "$nome" falhou "a aplicação já não respondia antes do teste"
    return 0
  fi
  pid="$(systemctl show -p MainPID --value elo-api)"
  antes="$(systemctl show -p NRestarts --value elo-api)"
  info "processo da API: pid $pid; reinícios pelo systemd até agora: $antes"
  kill -9 "$pid"
  inicio=$SECONDS
  info "processo morto; o site responde $(codigo_http http://127.0.0.1/health -H "Host: www.$DOMINIO") enquanto a API está fora"
  if esperar "a API voltar a responder 200 em /health" 90 app_saudavel && site_no_ar; then
    depois="$(systemctl show -p NRestarts --value elo-api)"
    info "novo processo: pid $(systemctl show -p MainPID --value elo-api); reinícios pelo systemd: $depois"
    registrar "$nome" passou "voltou em $((SECONDS - inicio))s; reinícios $antes -> $depois"
  else
    registrar "$nome" falhou "não voltou em 90s"
  fi
}

cenario_2() {
  local nome="2. Monitor morto à força" pid novo inicio
  passo "Cenário 2: o monitor é morto à força (kill -9)"
  pid="$(systemctl show -p MainPID --value elo-monitor)"
  if [[ -z $pid || $pid == 0 ]]; then
    registrar "$nome" falhou "o monitor não estava rodando antes do teste"
    return 0
  fi
  info "processo do monitor: pid $pid"
  kill -9 "$pid"
  inicio=$SECONDS
  monitor_de_volta() {
    novo="$(systemctl show -p MainPID --value elo-monitor)"
    [[ -n $novo && $novo != 0 && $novo != "$pid" ]] && systemctl is-active --quiet elo-monitor
  }
  if esperar "o systemd subir o monitor de novo" 40 monitor_de_volta; then
    info "novo processo: pid $novo"
    registrar "$nome" passou "voltou em $((SECONDS - inicio))s com outro pid ($pid -> $novo)"
  else
    registrar "$nome" falhou "não voltou em 40s"
  fi
}

# Para um serviço com "systemctl stop" (o systemd não religa parada manual) e espera o monitor agir.
servico_parado() { # servico_parado <nome do cenário> <serviço> <função que confere a volta>
  local nome="$1" servico="$2" conferir="$3" linhas inicio
  if ! systemctl is-active --quiet "$servico"; then
    registrar "$nome" falhou "o serviço $servico já estava parado antes do teste"
    return 0
  fi
  linhas="$(linhas_de_alerta)"
  executar "parar o serviço $servico" systemctl stop "$servico"
  inicio=$SECONDS
  info "esperando o monitor perceber (ele mede a cada ${INTERVALO_SEGUNDOS}s)"
  if esperar "o monitor subir o $servico de novo" "$ESPERA_DO_MONITOR" systemctl is-active --quiet "$servico" &&
    esperar "o serviço voltar a atender" 30 "$conferir" && alerta_novo "$linhas" "ALERTA servico:$servico"; then
    info "o que o monitor registrou em $ALERTAS:"
    mostrar_alertas_desde "$linhas"
    registrar "$nome" passou "alerta gerado e serviço de volta em $((SECONDS - inicio))s"
  else
    mostrar_alertas_desde "$linhas"
    systemctl start "$servico" 2>/dev/null || true
    registrar "$nome" falhou "o monitor não recuperou o serviço em ${ESPERA_DO_MONITOR}s (religado à mão)"
  fi
}

cenario_3() {
  passo "Cenário 3: o servidor web (Apache) é parado"
  servico_parado "3. Servidor web parado" apache2 site_no_ar
}

cenario_4() {
  passo "Cenário 4: o servidor DNS (BIND) é parado"
  servico_parado "4. Servidor DNS parado" named dns_no_ar
}

cenario_5() {
  local nome="5. CPU ocupada" linhas nucleos i
  passo "Cenário 5: a CPU fica ocupada (limite de alerta: ${LIMITE_CPU}%)"
  linhas="$(linhas_de_alerta)"
  nucleos="$(nproc)"
  info "ocupando $nucleos núcleo(s) com um laço vazio"
  for ((i = 0; i < nucleos; i++)); do
    (while :; do :; done) &
    CARGAS+=($!)
  done
  if esperar "o monitor gerar o alerta de CPU" "$ESPERA_DO_MONITOR" alerta_novo "$linhas" "ALERTA cpu"; then
    parar_cargas
    info "carga encerrada; esperando o aviso de volta ao normal"
    if esperar "o monitor avisar que a CPU normalizou" "$ESPERA_DO_MONITOR" alerta_novo "$linhas" "NORMALIZADO cpu"; then
      mostrar_alertas_desde "$linhas"
      registrar "$nome" passou "alerta e volta ao normal registrados"
    else
      mostrar_alertas_desde "$linhas"
      registrar "$nome" falhou "o alerta saiu, mas o aviso de volta ao normal não"
    fi
  else
    parar_cargas
    mostrar_alertas_desde "$linhas"
    registrar "$nome" falhou "o alerta de CPU não saiu em ${ESPERA_DO_MONITOR}s"
  fi
}

cenario_6() {
  local nome="6. Limites de memória e disco" linhas
  passo "Cenário 6: memória e disco acima do limite (um ciclo do monitor com limite de teste de 1%)"
  linhas="$(linhas_de_alerta)"
  info "encher a memória ou o disco de verdade arriscaria a VM; aqui o limite desce para 1% numa execução à parte"
  ELO_LIMITE_MEMORIA=1 ELO_LIMITE_DISCO=1 /usr/local/bin/elo-monitor --uma-vez --sem-acao 2>&1 | sed 's/^/      | /'
  if alerta_novo "$linhas" "ALERTA memoria" && alerta_novo "$linhas" "ALERTA disco:"; then
    registrar "$nome" passou "os dois alertas foram gravados em alertas.log"
  else
    registrar "$nome" falhou "faltou alerta de memória ou de disco"
  fi
}

# ---------------------------------------------------------------------------------------------------
passo "Situação antes dos testes"
[[ -x /usr/local/bin/elo-monitor ]] || falha "o monitor não está instalado: rode antes o provisionar.sh"
for servico in $SERVICOS_VIGIADOS elo-monitor; do
  info "$servico: $(systemctl is-active "$servico" 2>/dev/null || true)"
done
info "aplicação em /health: $(codigo_http "$URL_SAUDE")"

ESCOLHIDOS=("$@")
((${#ESCOLHIDOS[@]} > 0)) || ESCOLHIDOS=(1 2 3 4 5 6)
for numero in "${ESCOLHIDOS[@]}"; do
  case "$numero" in
    1 | 2 | 3 | 4 | 5 | 6) "cenario_$numero" ;;
    *) falha "cenário desconhecido: $numero (use de 1 a 6)" ;;
  esac
done

passo "Resultado"
echo
for linha in "${RESULTADOS[@]}"; do
  IFS='|' read -r cenario resultado detalhe <<<"$linha"
  printf '   [%s] %s: %s\n' "$resultado" "$cenario" "$detalhe"
  printf '%s [%s]    %s | %s | %s\n' "$(agora)" "$SCRIPT_ATUAL" "$cenario" "$resultado" "$detalhe" >>"$LOG_EXECUCAO"
done
echo
if ((FALHAS > 0)); then
  falha "$FALHAS cenário(s) falharam"
fi
ok "todos os cenários passaram: a infraestrutura se recuperou sozinha em cada um"
