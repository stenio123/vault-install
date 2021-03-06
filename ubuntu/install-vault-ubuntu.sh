#!/bin/bash 

# Installs Vault node for participation in raft cluster

if [ -z "$1" ]
  then
    echo "usage: $0 NODENAME"
    exit 1
fi

NODENAME=$1
if [ $EUID -ne 0 ]; then
    echo "This script should be run as root so it can install system packages and certificates." > /dev/stderr
    exit 1
fi

# Install prerequisites
echo "Updating system packages"
apt-get update
apt-get upgrade
apt install unzip vim openssl tree curl wget jq

# Setup hosts entry in case DNS not present
 echo `ifconfig eth0 | grep 'inet ' | awk '{print $2}'`  `hostname` >> /etc/hosts

BASEUSER=ubuntu

CERTS_FILE=/home/${BASEUSER}/certs.tgz
if [ ! -f "$CERTS_FILE" ]; then
    echo "Certificate tarball not found! $CERTS_FILE"
    exit 1
fi
tar -C /home/${BASEUSER} -xvf $CERTS_FILE

# Cross your fingers
cp /home/${BASEUSER}/ca.crt /usr/local/share/ca-certificates/vault-ca.crt
update-ca-certificates

# Disable Vault TLS verification, unless the centos update-ca-trust magically works for you
grep 'VAULT_SKIP_VERIFY=true' ~/.bashrc &>/dev/null || echo 'export VAULT_SKIP_VERIFY=true' >> ~/.bashrc





export PATH=${PATH}:/usr/local/bin

# Install latest Terraform to manage Vault namespaces as code
URL=`curl -s $tmpout https://www.terraform.io/downloads.html | grep linux_amd64.zip | cut -d'"' -f2`
wget $URL
file=`ls -tr terraform_*_linux_amd64.zip | tail -1`
rm -f terraform
unzip $file
cp terraform /usr/local/bin
terraform version


# Install latest Vault 
echo "Checking latest Vault version"
tmpout=.vault.version.check.$$
curl -s -o $tmpout https://www.vaultproject.io/downloads
VAULT_VERSION=`egrep -o '"version":".\..\.."'  $tmpout | head -1  | cut -f4 -d'"'`
rm $tmpout

# Put binary in place
# https://releases.hashicorp.com/vault/1.5.4+ent/vault_1.5.4+ent_linux_amd64.zip
echo "Downloading Vault https://releases.hashicorp.com/vault/${VAULT_VERSION}+ent/vault_${VAULT_VERSION}+ent_linux_amd64.zip"
curl --silent  --remote-name -o vault_${VAULT_VERSION}_linux_amd64.zip "https://releases.hashicorp.com/vault/${VAULT_VERSION}+ent/vault_${VAULT_VERSION}+ent_linux_amd64.zip"
unzip vault_${VAULT_VERSION}+ent_linux_amd64.zip
chown root:root vault
mv vault /usr/local/bin/
/usr/local/bin/vault -version

# Shell auto-complete
vault -autocomplete-install
complete -C /usr/local/bin/vault vault

# Allow mlock without requiring root privs
setcap cap_ipc_lock=+ep /usr/local/bin/vault

# Vault user and homedir, if doesn't exist
if ! getent passwd vault &>/dev/null
then
  useradd --system --home /etc/vault.d --shell /bin/false vault
fi

# Setup Vault server config 
mkdir --parents -m 750 /etc/vault.d /etc/ssl/vault
tar -C /etc/ssl/vault -zxvf $CERTS_FILE
chmod 640 /etc/ssl/vault/*
touch /etc/vault.d/vault.hcl
chown --recursive vault:vault /etc/vault.d /etc/ssl/vault
chmod 640 /etc/vault.d/vault.hcl
chmod 755 /etc/vault.d 
chmod 750 /etc/ssl/vault

# Add default centos user to vault group
usermod -a -G vault centos

IPADDR=`ifconfig eth0 | grep 'inet ' | awk '{print $2}'`

# Setup raft data directory
DATA=/var/vault/data
mkdir -p $DATA
chown -R vault:vault $DATA
chmod -R 750 $DATA

# Setup server config 
echo "Creating /etc/vault.d/vault.hcl"
cat > /etc/vault.d/vault.hcl <<EOF
storage "raft" {
    path    = "${DATA}"
    node_id = "${NODENAME}"
}

listener "tcp" {
  address            = "0.0.0.0:8200"
  cluster_address    = "0.0.0.0:8201"
  tls_cert_file      = "/etc/ssl/vault/vault.crt"
  tls_key_file       = "/etc/ssl/vault/vault.key"
  tls_client_ca_file = "/etc/ssl/vault/ca.crt"
}

cluster_addr = "https://${NODENAME}:8201"
api_addr = "https://${NODENAME}:8200"

ui = true

plugin_directory = "/etc/vault.d/plugins"
EOF

echo "Enabling vault.service in systemd"
# https://learn.hashicorp.com/tutorials/vault/raft-deployment-guide#configure-systemd
cat > /etc/systemd/system/vault.service <<EOF
[Unit]
Description="HashiCorp Vault - A tool for managing secrets"
Documentation=https://www.vaultproject.io/docs/
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=/etc/vault.d/vault.hcl
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
User=vault
Group=vault
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
SecureBits=keep-caps
AmbientCapabilities=CAP_IPC_LOCK
Capabilities=CAP_IPC_LOCK+ep
CapabilityBoundingSet=CAP_SYSLOG CAP_IPC_LOCK
NoNewPrivileges=yes
ExecStart=/usr/local/bin/vault server -config=/etc/vault.d/vault.hcl
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
LimitNOFILE=65536
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF

# Enable Vault
systemctl enable vault
systemctl start vault
systemctl status vault





