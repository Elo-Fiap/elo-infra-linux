# Gerado por scripts/02-aplicacao.sh (Elo).
# O Apache atende a rede na porta 80 e repassa tudo para a API, que só escuta em 127.0.0.1.
<VirtualHost *:80>
    ServerName www.@@DOMINIO@@
    ServerAlias @@DOMINIO@@ api.@@DOMINIO@@

    ProxyRequests Off
    ProxyPreserveHost On
    # retry=0: assim que a API volta, o Apache volta a repassar (não espera o minuto padrão).
    ProxyPass        / http://127.0.0.1:@@APP_PORTA@@/ retry=0
    ProxyPassReverse / http://127.0.0.1:@@APP_PORTA@@/

    # A API responde "Server: Kestrel". Sem esse cabeçalho, o cliente recebe só o do Apache.
    Header unset Server

    ErrorLog  ${APACHE_LOG_DIR}/elo-erro.log
    CustomLog ${APACHE_LOG_DIR}/elo-acesso.log combined
</VirtualHost>
