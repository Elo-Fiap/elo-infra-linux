#!/usr/bin/env bash
# provisionar: prepara a VM inteira, do zero até a aplicação no ar, num comando só.
#   1. scripts/01-infra.sh          rede, IP fixo, DNS e firewall
#   2. scripts/02-aplicacao.sh      dependências, variáveis, compilação, serviço e Apache
#   3. scripts/03-monitoramento.sh  monitor como serviço e rodízio dos logs
#   4. scripts/verificar.sh         confere tudo e grava a evidência
# Uso: sudo bash provisionar.sh
# Pode rodar de novo quando quiser: cada etapa só muda o que estiver diferente.

set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if ((EUID != 0)); then
  echo "Rode com sudo: sudo bash provisionar.sh" >&2
  exit 1
fi

INICIO=$SECONDS
for etapa in scripts/01-infra.sh scripts/02-aplicacao.sh scripts/03-monitoramento.sh scripts/verificar.sh; do
  echo
  if ! bash "$etapa"; then
    echo
    echo "O provisionamento parou em $etapa. O motivo está acima e em /var/log/elo/provisionamento.log." >&2
    exit 1
  fi
done
echo
echo "Provisionamento completo em $((SECONDS - INICIO))s."
echo "Para ver a infraestrutura reagindo a falhas: sudo bash scripts/teste-de-falha.sh"
