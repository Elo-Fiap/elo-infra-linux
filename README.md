# Elo: infraestrutura Linux

Operating Systems · FIAP Global Solution 2026.2 · CitizenTech

Scripts em Bash que preparam uma VM Ubuntu do zero para hospedar a aplicação do Elo: rede, DNS, a aplicação
publicada, o monitoramento como serviço, os logs e um teste de falha. Um comando faz tudo:

```bash
sudo bash provisionar.sh
```

O **Elo** é a chamada das ruas na chuva forte: quando o aviso de chuva chega, a liderança de cada rua responde
em um toque (tudo bem, água subindo ou preciso de ajuda), e quem coordena o bairro vê na hora quem pediu
ajuda e quem ficou em silêncio. A aplicação hospedada aqui é a **API do Elo em C#**, feita na disciplina de
C# Software Development ([Elo-Fiap/elo-api-csharp](https://github.com/Elo-Fiap/elo-api-csharp)). Ela serve o
resumo do bairro, o painel Risco Cidadão e a documentação da API.

## Integrantes

| Nome | RM |
| --- | --- |
| Bruno Leão | RM555563 |
| João Victor Franco | RM556790 |
| Lucca Borges | RM554608 |
| Rodrigo Jimenez | RM558148 |
| Ruan Melo | RM557599 |

**Vídeo de demonstração (até 7 minutos):** [preencher]

## O que cada critério pede e onde está

| Critério da GS | Pontos | Onde está |
| --- | --- | --- |
| Script de provisionamento de configurações de infra (redes, DNS, IP) | 2 | [`scripts/01-infra.sh`](scripts/01-infra.sh) |
| Script de provisionamento da aplicação (dependências, configurações, orquestração) | 2 | [`scripts/02-aplicacao.sh`](scripts/02-aplicacao.sh) |
| Script de monitoramento que gera alertas de CPU, disco e memória | 2 | [`scripts/elo-monitor.sh`](scripts/elo-monitor.sh) |
| Monitoramento como serviço tolerante a falhas | 1 | [`scripts/03-monitoramento.sh`](scripts/03-monitoramento.sh) e [`config/modelos/elo-monitor.service.tpl`](config/modelos/elo-monitor.service.tpl) |
| Logs de auditoria e de execução dos scripts | 1 | [`scripts/lib/comum.sh`](scripts/lib/comum.sh), gravados em `/var/log/elo/` |
| Funcionamento completo da proposta | 2 | [`provisionar.sh`](provisionar.sh) e [`scripts/verificar.sh`](scripts/verificar.sh) |
| Teste de falha | pilar | [`scripts/teste-de-falha.sh`](scripts/teste-de-falha.sh) |

## Como fica a VM

```
cliente da rede ──DNS──▶ BIND9 (named)          zona elo-fiap.com: www, api e ns1 apontam para a VM
       │
       └──HTTP :80──▶ Apache (proxy) ──▶ API do Elo (.NET 10, 127.0.0.1:5080) ──▶ SQLite em /var/lib/elo

elo-monitor (systemd) mede CPU, memória, disco e os três serviços a cada 15 s ──▶ /var/log/elo
```

- A API só escuta em `127.0.0.1`. Quem atende a rede é o Apache, que não informa a versão.
- O firewall (UFW) deixa entrar só SSH (22), DNS (53) e HTTP (80).
- `named`, `elo-api`, `apache2` e `elo-monitor` sobem na inicialização e voltam sozinhos se o processo morrer.

## Como rodar

Testado em Ubuntu 24.04. A VM precisa de internet para baixar os pacotes e o código da aplicação.

```bash
git clone https://github.com/Elo-Fiap/elo-infra-linux.git
```

```bash
cd elo-infra-linux
```

```bash
sudo bash provisionar.sh
```

A primeira execução leva alguns minutos, quase todos na compilação da API. Rodar de novo é rápido: cada
etapa só muda o que estiver diferente. Se o Ubuntu estiver atualizando pacotes sozinho na hora, os scripts
esperam o apt ficar livre (até 10 minutos) em vez de parar. Cada etapa também roda sozinha:

| Comando | O que faz |
| --- | --- |
| `sudo bash scripts/01-infra.sh` | hostname, IP fixo, BIND9 com a zona, resolução local e firewall |
| `sudo bash scripts/02-aplicacao.sh` | .NET 10, Git e Apache; usuário de serviço; variáveis; baixa, compila e publica a API; serviço e proxy |
| `sudo bash scripts/03-monitoramento.sh` | instala o monitor como serviço e o rodízio dos logs |
| `sudo bash scripts/verificar.sh` | confere rede, DNS, serviços, aplicação e logs, e grava a evidência |
| `sudo bash scripts/teste-de-falha.sh` | derruba cada peça de propósito e mostra a recuperação |

Depois do provisionamento, nos clientes da rede basta usar o IP da VM como servidor DNS e abrir
`http://www.elo-fiap.com`. As outras páginas: `/risco-cidadao.html` (painel de Cybersecurity), `/swagger`
(documentação) e `/health` (saúde da API e do banco).

## Configuração

Tudo que muda de uma VM para outra fica em [`config/elo.conf`](config/elo.conf): hostname, domínio, IP,
repositório da aplicação, porta, pastas e limites do monitor. Os scripts não precisam ser editados. Valor
vazio em `INTERFACE`, `IP_SERVIDOR`, `PREFIXO` e `GATEWAY` quer dizer "descubra na VM": o script fixa o
endereço que a placa já tem.

Os arquivos de sistema saem de modelos em [`config/modelos/`](config/modelos), com `@@NOME@@` no lugar de
cada valor. Antes de trocar um arquivo que já existia, o script guarda a versão original em
`/var/backups/elo/`.

| Modelo | Vira |
| --- | --- |
| `named.conf.options.tpl`, `named.conf.local.tpl`, `zona.db.tpl` | configuração e zona do BIND em `/etc/bind/` |
| `netplan-ip-fixo.yaml.tpl` | `/etc/netplan/60-elo.yaml` (em servidor sem NetworkManager) |
| `resolved-elo.conf.tpl` | a própria VM resolve o domínio pelo BIND local |
| `elo-api.env.tpl` | variáveis de ambiente da aplicação em `/etc/elo/elo-api.env` |
| `elo-api.service.tpl`, `elo-monitor.service.tpl` | serviços do systemd |
| `reinicio-automatico.conf.tpl` | reinício automático do `named` e do `apache2` |
| `apache-elo-vhost.conf.tpl`, `apache-elo-seguranca.conf.tpl` | proxy do Apache e servidor sem versão no cabeçalho |
| `monitor.conf.tpl`, `logrotate-elo.tpl` | limites do monitor e rodízio dos logs |

## 1. Infra: rede, DNS e IP

`scripts/01-infra.sh` faz, nesta ordem:

1. Descobre a placa da rota padrão, o IP, a máscara e a saída da rede.
2. Troca o hostname para `elo-srv` e grava o nome completo em `/etc/hosts`.
3. Fixa o IP. Em Ubuntu Desktop usa o NetworkManager (`nmcli`); em servidor, o netplan. Se a placa não ficar
   com o IP e a rota esperados, a configuração anterior volta.
4. Instala o BIND9 e gera a zona `elo-fiap.com` com `ns1`, `www`, `api` e o domínio apontando para a VM. O
   serial (`AAAAMMDDNN`) só sobe quando a zona muda. Valida com `named-checkconf` e `named-checkzone`.
5. Faz a própria VM resolver o domínio pelo BIND local.
6. Liga o firewall com as três portas.
7. Confere as respostas com `dig` e confirma que a transferência de zona é recusada.

## 2. Aplicação: dependências, configurações e orquestração

`scripts/02-aplicacao.sh` faz, nesta ordem:

1. **Dependências:** `dotnet-sdk-10.0`, `git`, `curl`, `openssl` e `apache2`, pelo `apt`.
2. **Usuário e pastas:** cria o usuário de serviço `elo`, sem login. O código fica em `/opt/elo-api`, o banco
   em `/var/lib/elo` e as variáveis em `/etc/elo`.
3. **Variáveis de ambiente** em `/etc/elo/elo-api.env`, lidas pelo systemd:

   | Variável | Valor | Para quê |
   | --- | --- | --- |
   | `ASPNETCORE_ENVIRONMENT` | `Production` | a API exige a chave do dispositivo |
   | `ASPNETCORE_URLS` | `http://127.0.0.1:5080` | só o Apache alcança a API |
   | `ConnectionStrings__Elo` | `Data Source=/var/lib/elo/elo.db` | banco fora da pasta do código |
   | `Dispositivos__Chave` | gerada na VM | chave da régua (ESP32); não vai para o log nem para o Git |
   | `Ia__Habilitada` | `false` | a VM não chama serviço de IA de fora |

4. **Código:** clona o repositório da API (ou busca a versão nova) e roda `dotnet publish` em modo Release.
   Só recompila quando o repositório mudou; a versão anterior fica guardada em `/opt/elo-api/app.anterior`.
5. **Serviço:** `elo-api.service`, com `Restart=always`, usuário sem privilégio e escrita só na pasta de dados.
6. **Apache:** ativa `proxy`, `proxy_http` e `headers`, publica o site `000-elo` e desativa o site padrão.
7. **Orquestração:** a ordem de subida é rede, `named`, `elo-api`, `apache2`. O script espera a API responder
   `200` em `/health` e depois confere as páginas pelo nome `www.elo-fiap.com`.

## 3. Monitoramento

`scripts/elo-monitor.sh` roda em laço e, a cada 15 segundos:

- mede o **uso de CPU** (média do intervalo, pelo `/proc/stat`), de **memória** (`/proc/meminfo`) e de
  **disco** (`df`);
- confere se `named`, `apache2` e `elo-api` estão ativos e se a API responde `200` em `/health`;
- grava uma linha de leitura em `/var/log/elo/monitor.log`.

Quando um valor passa do limite (CPU 80%, memória 80%, disco 85%), grava um **ALERTA** em
`/var/log/elo/alertas.log` e no journal. Enquanto o problema dura, o alerta se repete a cada 5 minutos;
quando o valor volta, grava **NORMALIZADO**. Serviço parado gera alerta e uma **ACAO**: o monitor pede ao
systemd para subir o serviço de novo. Exemplo das linhas (a primeira é do `monitor.log`, as outras do
`alertas.log`):

```
2026-11-19T16:20:31-0300 host=elo-srv cpu=3% memoria=41% disco[/]=38% servicos=named:active,apache2:active,elo-api:active saude_http=200
2026-11-19T16:21:02-0300 host=elo-srv ALERTA cpu: uso de CPU em 97% (limite 80%)
2026-11-19T16:21:47-0300 host=elo-srv NORMALIZADO cpu: uso de CPU voltou para 4% (limite 80%)
2026-11-19T16:22:18-0300 host=elo-srv ALERTA servico:apache2: o serviço está inactive
2026-11-19T16:22:18-0300 host=elo-srv ACAO servico:apache2: reinício pedido ao systemd: aceito
```

**Como serviço tolerante a falhas:** `scripts/03-monitoramento.sh` instala o monitor em
`/usr/local/bin/elo-monitor` e o `elo-monitor.service` com `Restart=always`, `RestartSec=5` e sem limite de
tentativas (`StartLimitIntervalSec=0`). Se o processo for morto, o systemd sobe outro em 5 segundos. Se a
pasta de logs for apagada, o monitor recria. Uma medição que falha não derruba o laço.

```bash
systemctl status elo-monitor
```

```bash
journalctl -u elo-monitor -f
```

```bash
sudo elo-monitor --uma-vez --sem-acao
```

## 4. Logs de execução e de auditoria

Tudo fica em `/var/log/elo/`, com rodízio semanal (`/etc/logrotate.d/elo`):

| Arquivo | O que tem |
| --- | --- |
| `provisionamento.log` | **execução dos scripts:** cada passo, cada comando rodado e a saída inteira dele |
| `auditoria.log` | **auditoria:** quem rodou qual script, quando, o que foi alterado e o resultado |
| `monitor.log` | as leituras do monitor |
| `alertas.log` | alertas, voltas ao normal e ações do monitor |

O resultado de cada cenário do teste de falha também entra em `provisionamento.log` e em `auditoria.log`.

Exemplo de uma linha da auditoria:

```
2026-11-19T16:18:04-0300 host=elo-srv usuario=ruan efetivo=root script=01-infra evento=arquivo detalhe="escrito /etc/bind/db.elo-fiap.com (modelo zona.db.tpl)"
```

Os eventos são `inicio`, `fim`, `arquivo`, `pacotes`, `servico`, `rede`, `hostname`, `usuario`, `firewall`,
`aplicacao`, `teste`, `aviso` e `erro`. A mesma linha vai para o journal:

```bash
journalctl -t elo-auditoria
```

Se um comando falha, o script para, mostra o fim da saída do comando e registra o erro com o número da
linha e o passo em que estava.

## 5. Teste de falha

`scripts/teste-de-falha.sh` provoca seis situações e confere a reação:

| Cenário | O que o teste faz | O que tem de acontecer |
| --- | --- | --- |
| 1. Aplicação morta à força | `kill -9` no processo da API | o systemd sobe outro e `/health` volta a responder 200 |
| 2. Monitor morto à força | `kill -9` no processo do monitor | o systemd sobe outro, com outro PID |
| 3. Servidor web parado | `systemctl stop apache2` | o monitor alerta e manda subir; o site volta |
| 4. Servidor DNS parado | `systemctl stop named` | o monitor alerta e manda subir; o DNS volta a responder |
| 5. CPU ocupada | um laço vazio por núcleo | sai o ALERTA de CPU e, depois, o NORMALIZADO |
| 6. Memória e disco | um ciclo do monitor com limite de 1% | saem os alertas de memória e de disco |

No cenário 6 o limite desce para 1% numa execução à parte, porque encher a memória ou o disco de verdade
arriscaria a VM. O teste termina com uma tabela de resultado e grava a saída em `evidencias/`.

```bash
sudo bash scripts/teste-de-falha.sh
```

```bash
sudo bash scripts/teste-de-falha.sh 1 3
```

## Evidências

A pasta [`evidencias/`](evidencias) guarda o que foi gravado na VM:

- `verificacao-<data>.txt`: saída do `scripts/verificar.sh`;
- `teste-de-falha-<data>.txt`: saída do teste de falha;
- `logs-<data>/`: cópia dos logs de `/var/log/elo/` e do journal dos serviços no momento da verificação.

## Estrutura do repositório

```
provisionar.sh              roda as etapas em ordem
config/elo.conf             variáveis do provisionamento
config/modelos/             modelos dos arquivos de sistema
scripts/lib/comum.sh        log de execução, auditoria e funções comuns
scripts/01-infra.sh         rede, IP, DNS e firewall
scripts/02-aplicacao.sh     dependências, variáveis, compilação, serviço e proxy
scripts/03-monitoramento.sh monitor como serviço e rodízio dos logs
scripts/elo-monitor.sh      o monitor
scripts/verificar.sh        conferência completa e coleta de evidências
scripts/teste-de-falha.sh   teste de falha
evidencias/                 saídas gravadas na VM
```

## Limites conhecidos

- O site é servido em HTTP, sem certificado: o domínio `elo-fiap.com` só existe dentro da rede da VM.
- A zona tem um servidor de nomes só (`ns1`) e a transferência de zona está bloqueada para todos.
- O monitor avisa pelo log e pelo journal; não envia e-mail nem mensagem.
- Os dados da aplicação são simulados (bairro e ruas de exemplo criados na primeira execução). Nenhum dado
  pessoal real é usado.

## Uso de IA

Os scripts foram escritos com a ajuda do Claude Code (Anthropic).
