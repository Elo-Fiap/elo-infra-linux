#!/usr/bin/env bash
# Funções comuns dos scripts do Elo: configuração, log de execução, trilha de auditoria e utilitários.
# Uso, no começo de cada script:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/comum.sh"
#   iniciar "01-infra" "$@"

set -Eeuo pipefail
shopt -u patsub_replacement 2>/dev/null || true # bash 5.2: "&" no texto trocado não é especial

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARQ_CONFIG="${ELO_CONFIG:-$RAIZ/config/elo.conf}"
[[ -r $ARQ_CONFIG ]] || { echo "Não achei a configuração em $ARQ_CONFIG" >&2; exit 1; }
# shellcheck source=../../config/elo.conf
source "$ARQ_CONFIG"
# shellcheck source=/dev/null
[[ -r $RAIZ/config/elo.local.conf ]] && source "$RAIZ/config/elo.local.conf"

LOG_EXECUCAO="$DIR_LOG/provisionamento.log"
LOG_AUDITORIA="$DIR_LOG/auditoria.log"
DIR_COPIAS="/var/backups/elo" # primeira versão de cada arquivo de sistema que os scripts trocam
QUEM="${SUDO_USER:-$(id -un)}"
SCRIPT_ATUAL="-"
PASSO_ATUAL="início"
N_PASSO=0
MUDOU="nao"
INICIO_SCRIPT=$SECONDS

agora() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# ---------- Log de execução: cada linha vai para a tela e para o arquivo ----------
log() {
  printf '%s [%s] %s\n' "$(agora)" "$SCRIPT_ATUAL" "$*" >>"$LOG_EXECUCAO"
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}
passo() {
  N_PASSO=$((N_PASSO + 1))
  PASSO_ATUAL="$*"
  log "── passo $N_PASSO: $*"
}
ok() { log "   ok: $*"; }
info() { log "   $*"; }
aviso() {
  log "   AVISO: $*"
  auditar aviso "$*"
}
falha() {
  log "   ERRO: $*"
  auditar erro "$*"
  exit 1
}

# ---------- Trilha de auditoria: quem rodou o quê, quando e com que resultado ----------
# Uma linha por evento, no arquivo e no journal (journalctl -t elo-auditoria).
auditar() {
  local linha
  linha="$(agora) host=$(hostname) usuario=$QUEM efetivo=$(id -un) script=$SCRIPT_ATUAL evento=$1 detalhe=\"${2:-}\""
  printf '%s\n' "$linha" >>"$LOG_AUDITORIA"
  logger -t elo-auditoria -p auth.notice -- "$linha" 2>/dev/null || true
}

_ao_falhar() {
  local codigo=$?
  log "   ERRO na linha $1: $2 (código $codigo)"
  auditar erro "linha $1: $2 (código $codigo)"
}
_ao_sair() {
  local codigo="${1:-$?}" duracao=$((SECONDS - INICIO_SCRIPT))
  if ((codigo == 0)); then
    log "═══ $SCRIPT_ATUAL: concluído em ${duracao}s ═══"
    auditar fim "sucesso em ${duracao}s"
  else
    log "═══ $SCRIPT_ATUAL: FALHOU no passo \"$PASSO_ATUAL\" (código $codigo). Detalhes em $LOG_EXECUCAO ═══"
    auditar fim "falha (código $codigo) no passo: $PASSO_ATUAL"
  fi
}

# Chamada no começo de cada script: exige root, prepara os logs e registra o início.
iniciar() {
  SCRIPT_ATUAL="$1"
  shift || true
  if ((EUID != 0)); then
    echo "Este script muda a configuração do sistema. Rode com sudo: sudo bash $0" >&2
    exit 1
  fi
  install -d -m 750 -o root -g adm "$DIR_LOG"
  touch "$LOG_EXECUCAO" "$LOG_AUDITORIA"
  chown root:adm "$LOG_EXECUCAO" "$LOG_AUDITORIA"
  chmod 640 "$LOG_EXECUCAO" "$LOG_AUDITORIA"
  INICIO_SCRIPT=$SECONDS
  trap '_ao_falhar "$LINENO" "$BASH_COMMAND"' ERR
  trap '_ao_sair "$?"' EXIT
  log "═══ $SCRIPT_ATUAL: início, por $QUEM em $(hostname) ═══"
  auditar inicio "argumentos: ${*:-nenhum}"
}

# Roda o script de novo gravando tudo que sai na tela em evidencias/<nome>-<data>.txt.
# Chamar antes de iniciar: gravar_evidencia "teste-de-falha" "$@"
gravar_evidencia() {
  [[ -n ${ELO_GRAVANDO:-} ]] && return 0
  local nome="$1" arquivo codigo
  shift
  install -d "$RAIZ/evidencias"
  arquivo="$RAIZ/evidencias/$nome-$(date +%Y%m%d-%H%M%S).txt"
  set +e
  ELO_GRAVANDO="$arquivo" bash "$0" "$@" 2>&1 | tee "$arquivo"
  codigo=${PIPESTATUS[0]}
  set -e
  if [[ -n ${SUDO_USER:-} ]]; then chown -R "$SUDO_USER": "$RAIZ/evidencias" 2>/dev/null || true; fi
  echo "Evidência gravada em $arquivo"
  exit "$codigo"
}

# ---------- Utilitários ----------

# executar "descrição" comando...   A saída inteira vai para o log; se falhar, mostra o fim dela e para.
executar() {
  local descricao="$1" codigo=0 saida
  shift
  saida="$(mktemp)"
  printf '%s [%s] $ %s\n' "$(agora)" "$SCRIPT_ATUAL" "$*" >>"$LOG_EXECUCAO"
  "$@" >"$saida" 2>&1 || codigo=$?
  cat "$saida" >>"$LOG_EXECUCAO"
  if ((codigo == 0)); then
    rm -f "$saida"
    ok "$descricao"
    return 0
  fi
  log "   ERRO (código $codigo): $descricao"
  tail -n 12 "$saida" | sed 's/^/      | /'
  rm -f "$saida"
  auditar erro "$descricao (código $codigo)"
  exit "$codigo"
}

# esperar "descrição" <segundos> comando...   Repete o comando até dar certo ou o tempo acabar.
esperar() {
  local descricao="$1" limite="$2" inicio=$SECONDS
  shift 2
  until "$@" >/dev/null 2>&1; do
    if ((SECONDS - inicio >= limite)); then
      log "   ERRO: \"$descricao\" não aconteceu em ${limite}s"
      return 1
    fi
    sleep 1
  done
  ok "$descricao (em $((SECONDS - inicio))s)"
}

# apt_com_espera "descrição" comando do apt...
# Igual ao executar, mas se outro processo estiver usando o apt (o Ubuntu costuma se atualizar sozinho logo
# depois de ligar), espera e tenta de novo por até 10 minutos em vez de parar.
# O comando roda com LC_ALL=C para a mensagem de trava vir sempre em inglês.
apt_com_espera() {
  local descricao="$1" codigo saida inicio=$SECONDS avisou="nao"
  shift
  saida="$(mktemp)"
  while :; do
    codigo=0
    printf '%s [%s] $ %s\n' "$(agora)" "$SCRIPT_ATUAL" "$*" >>"$LOG_EXECUCAO"
    env LC_ALL=C DEBIAN_FRONTEND=noninteractive "$@" >"$saida" 2>&1 || codigo=$?
    cat "$saida" >>"$LOG_EXECUCAO"
    if ((codigo == 0)); then
      rm -f "$saida"
      ok "$descricao"
      return 0
    fi
    if ((SECONDS - inicio < 600)) && grep -qiE 'could not get lock|unable to (acquire|lock)|held by process' "$saida"; then
      if [[ $avisou == nao ]]; then
        info "outro processo está usando o apt (o Ubuntu se atualizando sozinho); esperando ele terminar"
        avisou="sim"
      fi
      sleep 10
      continue
    fi
    log "   ERRO (código $codigo): $descricao"
    tail -n 12 "$saida" | sed 's/^/      | /'
    rm -f "$saida"
    auditar erro "$descricao (código $codigo)"
    exit "$codigo"
  done
}

atualizar_indice() {
  local marca=/run/elo-apt-atualizado # some no reinício da máquina
  if [[ -n "$(find "$marca" -mmin -60 2>/dev/null)" ]]; then
    return 0
  fi
  apt_com_espera "atualizar a lista de pacotes (apt-get update)" apt-get -o DPkg::Lock::Timeout=60 update
  touch "$marca"
}

# instalar pacote...   Só instala o que falta.
instalar() {
  local faltam=() pacote
  for pacote in "$@"; do
    dpkg-query -W -f='${Status}' "$pacote" 2>/dev/null | grep -q 'install ok installed' || faltam+=("$pacote")
  done
  if ((${#faltam[@]} == 0)); then
    ok "pacotes já instalados: $*"
    return 0
  fi
  atualizar_indice
  apt_com_espera "instalar pacotes: ${faltam[*]}" \
    apt-get -o DPkg::Lock::Timeout=60 install -y --no-install-recommends "${faltam[@]}"
  auditar pacotes "instalados: ${faltam[*]}"
}

# montar <modelo>
# Escreve na saída o arquivo config/modelos/<modelo> com cada @@NOME@@ trocado pelo valor da variável NOME.
montar() {
  local modelo="$RAIZ/config/modelos/$1" conteudo nome
  [[ -r $modelo ]] || falha "modelo não encontrado: $modelo"
  conteudo="$(<"$modelo")"
  while [[ $conteudo =~ @@([A-Z0-9_]+)@@ ]]; do
    nome="${BASH_REMATCH[1]}"
    [[ -v $nome ]] || falha "o modelo $1 usa @@$nome@@, que não está definida"
    conteudo="${conteudo//@@$nome@@/${!nome}}"
  done
  printf '%s\n' "$conteudo"
}

# renderizar <modelo> <destino> [modo]
# Grava o modelo preenchido em <destino>. Só escreve se o conteúdo mudou (MUDOU=sim|nao) e guarda a
# primeira versão do arquivo que já existia em $DIR_COPIAS.
renderizar() {
  local destino="$2" modo="${3:-644}" tmp
  tmp="$(mktemp)"
  montar "$1" >"$tmp"
  if [[ -f $destino ]] && cmp -s "$tmp" "$destino"; then
    rm -f "$tmp"
    MUDOU="nao"
    info "sem mudança: $destino"
    return 0
  fi
  if [[ -f $destino && ! -e $DIR_COPIAS$destino ]]; then
    install -d -m 700 "$(dirname "$DIR_COPIAS$destino")"
    cp -a "$destino" "$DIR_COPIAS$destino"
    info "cópia do arquivo original em $DIR_COPIAS$destino"
  fi
  install -d "$(dirname "$destino")"
  install -m "$modo" "$tmp" "$destino"
  rm -f "$tmp"
  MUDOU="sim"
  ok "escrito: $destino"
  auditar arquivo "escrito $destino (modelo $1)"
}

# Preenche INTERFACE, IP_SERVIDOR, PREFIXO e GATEWAY com o que a VM tem hoje, quando o elo.conf deixa vazio.
descobrir_rede() {
  local atual
  if [[ -z $INTERFACE ]]; then
    INTERFACE="$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
  fi
  [[ -n $INTERFACE ]] || falha "não achei a placa de rede da rota padrão; defina INTERFACE em config/elo.conf"
  atual="$(ip -4 -o addr show dev "$INTERFACE" scope global | awk '{print $4; exit}')"
  [[ -n $IP_SERVIDOR ]] || IP_SERVIDOR="${atual%/*}"
  [[ -n $PREFIXO ]] || PREFIXO="${atual#*/}"
  [[ -n $GATEWAY ]] || GATEWAY="$(ip -4 route show default dev "$INTERFACE" 2>/dev/null | awk '{print $3; exit}')"
  [[ -n $IP_SERVIDOR && -n $PREFIXO ]] || falha "a placa $INTERFACE não tem IPv4; defina IP_SERVIDOR e PREFIXO em config/elo.conf"
}

# Código HTTP de uma URL (000 quando não conecta). Argumentos extras vão para o curl.
codigo_http() {
  local url="$1"
  shift
  curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$@" "$url" 2>/dev/null || true
}
