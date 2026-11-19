// Gerado por scripts/01-infra.sh (Elo).
zone "@@DOMINIO@@" {
        type master;
        file "/etc/bind/db.@@DOMINIO@@";
        allow-transfer { none; };
};
