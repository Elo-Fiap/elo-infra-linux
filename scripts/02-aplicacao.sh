#!/usr/bin/env bash
# 02-aplicacao: instala o que a aplicação precisa, baixa e publica a API do Elo e a coloca no ar.
#   dependências (.NET 10, Git, Apache), usuário de serviço, variáveis de ambiente, compilação,
#   serviço systemd, proxy no Apache e ordem de subida dos serviços.
# Critério da GS: "Script de provisionamento da aplicação (dependências, configurações, orquestração)".
# A aplicação é a API em C# do Elo (https://github.com/Elo-Fiap/elo-api-csharp), feita em outra disciplina.
# Uso: sudo bash scripts/02-aplicacao.sh
# Pode rodar quantas vezes quiser: só recompila quando o repositório tem versão nova.

# shellcheck source=lib/comum.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/comum.sh"
iniciar "02-aplicacao" "$@"

DIR_FONTE="$DIR_APP/fonte"
DIR_BIN="$DIR_APP/app"
URL_SAUDE="http://127.0.0.1:$APP_PORTA/health"

# ---------------------------------------------------------------------------------------------------
passo "Dependências: Git, curl, .NET SDK 10 e Apache"
instalar ca-certificates curl git openssl dotnet-sdk-10.0 apache2
DOTNET_BIN="$(command -v dotnet)"
dotnet --list-sdks 2>/dev/null | grep -q '^10\.' || falha "o .NET SDK 10 não ficou instalado"
info ".NET SDK $(dotnet --version 2>/dev/null), $(apache2 -v | head -n1 | sed 's/Server version: //'), $(git --version)"

# ---------------------------------------------------------------------------------------------------
passo "Usuário de serviço e pastas"
if id "$APP_USUARIO" >/dev/null 2>&1; then
  ok "usuário $APP_USUARIO já existe"
else
  executar "criar o usuário $APP_USUARIO (sem login)" \
    useradd --system --home-dir "$DIR_DADOS" --no-create-home --shell /usr/sbin/nologin "$APP_USUARIO"
  auditar usuario "criado o usuário de serviço $APP_USUARIO"
fi
install -d -m 755 -o root -g root "$DIR_APP"
install -d -m 750 -o "$APP_USUARIO" -g "$APP_USUARIO" "$DIR_DADOS"
install -d -m 750 -o root -g "$APP_USUARIO" "$DIR_CONFIG"
ok "pastas: $DIR_APP (código), $DIR_DADOS (banco), $DIR_CONFIG (variáveis)"

# ---------------------------------------------------------------------------------------------------
passo "Variáveis de ambiente da aplicação ($DIR_CONFIG/elo-api.env)"
# A chave da régua (ESP32) é criada uma vez e mantida nas próximas execuções. Ela nunca vai para o log.
CHAVE_DISPOSITIVO="$(sed -n 's/^Dispositivos__Chave=//p' "$DIR_CONFIG/elo-api.env" 2>/dev/null || true)"
if [[ -z $CHAVE_DISPOSITIVO ]]; then
  CHAVE_DISPOSITIVO="$(openssl rand -hex 16)"
  info "chave do dispositivo criada (fica só em $DIR_CONFIG/elo-api.env)"
fi
renderizar elo-api.env.tpl "$DIR_CONFIG/elo-api.env" 640
chown root:"$APP_USUARIO" "$DIR_CONFIG/elo-api.env"
MUDOU_VARIAVEIS="$MUDOU"
info "ambiente Production, porta $APP_PORTA só em 127.0.0.1, banco em $DIR_DADOS/elo.db, IA desligada"

# ---------------------------------------------------------------------------------------------------
passo "Código da aplicação ($APP_REPOSITORIO, ramo $APP_RAMO)"
if [[ -d $DIR_FONTE/.git ]]; then
  executar "buscar a versão mais nova" git -C "$DIR_FONTE" fetch --depth 1 origin "$APP_RAMO"
  executar "usar a versão baixada" git -C "$DIR_FONTE" reset --hard FETCH_HEAD
else
  executar "clonar o repositório" git clone --depth 1 --branch "$APP_RAMO" "$APP_REPOSITORIO" "$DIR_FONTE"
fi
VERSAO="$(git -C "$DIR_FONTE" rev-parse --short HEAD)"
info "versão do código: $VERSAO ($(git -C "$DIR_FONTE" log -1 --format=%s | cut -c1-70))"

# ---------------------------------------------------------------------------------------------------
passo "Compilar e publicar a aplicação"
MUDOU_APP="nao"
if [[ -f $DIR_BIN/Elo.Api.dll && "$(cat "$DIR_APP/VERSAO" 2>/dev/null)" == "$VERSAO" ]]; then
  ok "a versão $VERSAO já está publicada em $DIR_BIN"
else
  rm -rf "$DIR_APP/app.novo"
  info "dotnet publish (a primeira vez baixa os pacotes e leva alguns minutos)"
  executar "compilar em modo Release" env HOME=/root DOTNET_NOLOGO=1 DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    dotnet publish "$DIR_FONTE/src/Elo.Api" -c Release -o "$DIR_APP/app.novo"
  [[ -f $DIR_APP/app.novo/Elo.Api.dll ]] || falha "a publicação não gerou Elo.Api.dll"
  systemctl stop elo-api 2>/dev/null || true
  rm -rf "$DIR_APP/app.anterior"
  [[ -d $DIR_BIN ]] && mv "$DIR_BIN" "$DIR_APP/app.anterior"
  mv "$DIR_APP/app.novo" "$DIR_BIN"
  echo "$VERSAO" >"$DIR_APP/VERSAO"
  MUDOU_APP="sim"
  ok "versão $VERSAO publicada em $DIR_BIN (a anterior fica em $DIR_APP/app.anterior)"
  auditar aplicacao "publicada a versão $VERSAO de $APP_REPOSITORIO"
fi

# ---------------------------------------------------------------------------------------------------
passo "Serviço da aplicação (systemd: elo-api.service)"
renderizar elo-api.service.tpl /etc/systemd/system/elo-api.service
MUDOU_SERVICO="$MUDOU"
[[ $MUDOU_SERVICO == sim ]] && systemctl daemon-reload
executar "ligar a aplicação na inicialização" systemctl enable elo-api
if [[ $MUDOU_APP == sim || $MUDOU_SERVICO == sim || $MUDOU_VARIAVEIS == sim ]] || ! systemctl is-active --quiet elo-api; then
  executar "subir a aplicação" systemctl restart elo-api
  auditar servico "elo-api reiniciado"
else
  ok "a aplicação já estava rodando nesta versão"
fi
api_saudavel() { [[ "$(codigo_http "$URL_SAUDE")" == 200 ]]; }
if ! esperar "a API responder 200 em /health" 90 api_saudavel; then
  journalctl -u elo-api -n 25 --no-pager 2>/dev/null | sed 's/^/      | /' || true
  falha "a aplicação não respondeu em $URL_SAUDE"
fi

# ---------------------------------------------------------------------------------------------------
passo "Apache: recebe a rede na porta 80 e repassa para a API"
PRECISA_REINICIAR_APACHE="nao"
renderizar apache-elo-seguranca.conf.tpl /etc/apache2/conf-available/zz-elo-seguranca.conf
[[ $MUDOU == sim ]] && PRECISA_REINICIAR_APACHE="sim"
renderizar apache-elo-vhost.conf.tpl /etc/apache2/sites-available/000-elo.conf
[[ $MUDOU == sim ]] && PRECISA_REINICIAR_APACHE="sim"
for modulo in proxy proxy_http headers; do
  if [[ ! -e /etc/apache2/mods-enabled/$modulo.load ]]; then
    executar "ativar o módulo $modulo" a2enmod "$modulo"
    PRECISA_REINICIAR_APACHE="sim"
  fi
done
if [[ ! -e /etc/apache2/conf-enabled/zz-elo-seguranca.conf ]]; then
  executar "ativar a configuração de segurança" a2enconf zz-elo-seguranca
  PRECISA_REINICIAR_APACHE="sim"
fi
if [[ ! -e /etc/apache2/sites-enabled/000-elo.conf ]]; then
  executar "ativar o site do Elo" a2ensite 000-elo
  PRECISA_REINICIAR_APACHE="sim"
fi
# Sai o site padrão do Apache e qualquer outro site que responda pelo mesmo domínio.
for arquivo in /etc/apache2/sites-enabled/*.conf; do
  [[ -e $arquivo ]] || continue
  site="$(basename "$arquivo" .conf)"
  [[ $site == 000-elo ]] && continue
  if [[ $site == 000-default ]] || grep -qiE "Server(Name|Alias).*${DOMINIO//./\\.}" "$arquivo"; then
    executar "desativar o site $site" a2dissite "$site"
    auditar apache "site $site desativado"
    PRECISA_REINICIAR_APACHE="sim"
  fi
done
executar "validar a configuração do Apache" apache2ctl configtest
renderizar reinicio-automatico.conf.tpl /etc/systemd/system/apache2.service.d/elo-reinicio.conf
[[ $MUDOU == sim ]] && systemctl daemon-reload
executar "ligar o Apache na inicialização" systemctl enable apache2
if [[ $PRECISA_REINICIAR_APACHE == sim ]] || ! systemctl is-active --quiet apache2; then
  executar "reiniciar o Apache" systemctl restart apache2
  auditar servico "apache2 reiniciado"
else
  ok "Apache já estava rodando com esta configuração"
fi

# ---------------------------------------------------------------------------------------------------
passo "Conferir a aplicação de ponta a ponta"
site_pelo_apache() { [[ "$(codigo_http http://127.0.0.1/health -H "Host: www.$DOMINIO")" == 200 ]]; }
esperar "o Apache repassar /health para a API" 30 site_pelo_apache
BANNER="$(curl -sI --max-time 4 -H "Host: www.$DOMINIO" http://127.0.0.1/ | tr -d '\r' | sed -n 's/^Server: //Ip' || true)"
info "cabeçalho Server que o cliente recebe: ${BANNER:-nenhum}"
[[ $BANNER == Apache ]] || aviso "o cabeçalho Server deveria ser só \"Apache\""
IP_DO_NOME=""
if command -v dig >/dev/null; then
  IP_DO_NOME="$(dig +short +time=2 +tries=1 @127.0.0.1 "www.$DOMINIO" A 2>/dev/null | tail -n1 || true)"
fi
if [[ -n $IP_DO_NOME ]]; then
  for caminho in / /health /risco-cidadao.html /swagger/index.html; do
    CODIGO="$(codigo_http "http://www.$DOMINIO$caminho" --resolve "www.$DOMINIO:80:$IP_DO_NOME")"
    [[ $CODIGO == 200 ]] || falha "http://www.$DOMINIO$caminho respondeu $CODIGO (esperado 200)"
    ok "http://www.$DOMINIO$caminho -> 200 (pelo DNS da VM: $IP_DO_NOME)"
  done
else
  aviso "o DNS local não respondeu por www.$DOMINIO: rode antes o scripts/01-infra.sh"
fi
info "ordem de subida na inicialização: rede -> named (DNS) -> elo-api -> apache2; todos com reinício automático"
