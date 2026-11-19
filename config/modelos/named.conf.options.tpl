// Gerado por scripts/01-infra.sh (Elo). Não edite à mão: mude config/elo.conf e rode o script de novo.
options {
        directory "/var/cache/bind";

        // O que não é da zona do projeto é perguntado a estes servidores.
        forwarders { @@ENCAMINHADORES@@ };

        // Só a própria rede pode usar este servidor para resolver nomes de fora.
        allow-recursion { localhost; localnets; };

        // Ninguém copia a zona inteira (AXFR).
        allow-transfer { none; };

        // Não informa a versão do BIND a quem pergunta.
        version "nao informado";

        dnssec-validation auto;
        listen-on-v6 { any; };
};
