; Zona direta @@DOMINIO@@ - Projeto Elo (FIAP Global Solution 2026.2)
; Gerado por scripts/01-infra.sh. Não edite à mão: mude config/elo.conf e rode o script de novo.
$TTL 600
@       IN      SOA     ns1.@@DOMINIO@@. admin.@@DOMINIO@@. (
                        @@SERIAL@@      ; serial (AAAAMMDDNN)
                        28800           ; refresh (8 horas)
                        14400           ; retry (4 horas)
                        86400           ; expire (1 dia)
                        600 )           ; TTL negativo (10 minutos)

; Servidor de nomes
@       IN      NS      ns1.@@DOMINIO@@.
ns1     IN      A       @@IP_SERVIDOR@@

; A aplicação: o Apache recebe em www e repassa para a API do Elo
@       IN      A       @@IP_SERVIDOR@@
www     IN      A       @@IP_SERVIDOR@@
api     IN      CNAME   www
