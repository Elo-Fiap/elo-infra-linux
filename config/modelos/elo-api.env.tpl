# Variáveis de ambiente da API do Elo. Gerado por scripts/02-aplicacao.sh.
# Lido pelo systemd (EnvironmentFile do elo-api.service). Só root e o usuário de serviço leem este arquivo.
ASPNETCORE_ENVIRONMENT=Production
ASPNETCORE_URLS=http://127.0.0.1:@@APP_PORTA@@
ConnectionStrings__Elo="Data Source=@@DIR_DADOS@@/elo.db"
Dispositivos__Chave=@@CHAVE_DISPOSITIVO@@
Ia__Habilitada=false
DOTNET_NOLOGO=1
DOTNET_CLI_TELEMETRY_OPTOUT=1
HOME=@@DIR_DADOS@@
