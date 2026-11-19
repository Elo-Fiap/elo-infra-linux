# Gerado por scripts/01-infra.sh (Elo). IP fixo do servidor.
network:
  version: 2
  ethernets:
    @@INTERFACE@@:
      dhcp4: false
      addresses: [@@IP_SERVIDOR@@/@@PREFIXO@@]
      routes:
        - to: default
          via: @@GATEWAY@@
      nameservers:
        addresses: [@@DNS_DA_PLACA@@]
