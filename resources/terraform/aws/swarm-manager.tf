locals {
  manager_user_data = <<TFEOF
#!/bin/sh

export DEBIAN_FRONTEND=noninteractive

# Mount external volume as docker lib

while true; do
  sleep 1
  test -e /dev/xvdh && break
done

mkfs -t ext4 /dev/xvdh
mkdir /var/lib/docker
cp /etc/fstab /etc/fstab.bak
echo '/dev/xvdh /var/lib/docker ext4 defaults,nofail 0 0' >> /etc/fstab
mount -a

# Sysctl

sysctl -w net.core.somaxconn=128000

# Remove old instances of Docker which might ship with ubuntu
apt-get remove docker docker-engine docker.io

apt-get update
apt-get install \
    apt-transport-https \
    ca-certificates \
    curl \
    software-properties-common

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
# Complete fingerprint: 9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88
apt-key fingerprint 0EBFCD88

add-apt-repository \
  "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) \
  stable"

apt-get update
apt-get install -y docker-ce
docker plugin install --grant-all-permissions rexray/ebs

curl -L https://s3.amazonaws.com/orbs-network-releases/infrastructure/boyar/boyar-${var.boyar_version}.bin -o /usr/bin/boyar && chmod +x /usr/bin/boyar

apt-get install -y python-pip && pip install awscli

docker swarm init

mkdir -p /opt/orbs
aws secretsmanager get-secret-value --region ${var.region} --secret-id orbs-network-node-keys-${var.context_id} --output text --query SecretBinary | base64 -d > /opt/orbs/keys.json

aws secretsmanager create-secret --region ${var.region} --name swarm-token-${var.run_identifier}-worker-${var.region} --secret-string $(docker swarm join-token --quiet worker) || aws secretsmanager put-secret-value --region ${var.region} --secret-id swarm-token-${var.run_identifier}-worker-${var.region} --secret-string $(docker swarm join-token --quiet worker)

$(aws ecr get-login --no-include-email --region us-west-2)

echo '0 * * * * $(/usr/local/bin/aws ecr get-login --no-include-email --region us-west-2)' > /tmp/crontab
crontab /tmp/crontab

# Wait for everyone to join the swarm
while true; do
    [ $(docker node ls --format '{{.ID}} {{.ManagerStatus}}' | grep -v Leader | wc -l) -ge ${var.aws_orbs_worker_instance_count} ] && break
    sleep 15
done

# Label workers
for n in $(docker node ls --format '{{.ID}} {{.ManagerStatus}}' | grep -v Leader | cut -d" " -f1); do
    docker node update --label-add worker=true $n
done

# Label leader as manager
for n in $(docker node ls --format '{{.ID}} {{.ManagerStatus}}' | grep Leader | cut -d" " -f1); do
    docker node update --label-add manager=true $n
done

# Extract topology from Ethereum if possible
if [ ! -z "${var.ethereum_topology_contract_address}" ]; then
  export ETHEREUM_PARAMS="--ethereum-endpoint http://172.31.100.100:8545 --topology-contract-address ${var.ethereum_topology_contract_address}"
fi

HOME=/root nohup boyar --config-url ${var.s3_boyar_config_url} --keys /opt/orbs/keys.json --daemonize --max-reload-time-delay 15m $ETHEREUM_PARAMS > /var/log/boyar.log &

TFEOF
}

resource "aws_instance" "manager" {
  ami                  = "${data.aws_ami.ubuntu-18_04.id}"
  instance_type        = "${var.aws_orbs_manager_instance_type}"
  security_groups      = ["${aws_security_group.swarm.id}"]
  key_name             = "${aws_key_pair.deployer.key_name}"
  subnet_id            = "${ module.vpc.subnet-ids-public[0] }"
  iam_instance_profile = "${ aws_iam_instance_profile.swarm_manager.name }"

  user_data = "${local.manager_user_data}"

  tags = {
    Name = "constellation-${var.run_identifier}-swarm-manager"
  }
}

resource "aws_ebs_volume" "manager_storage" {
  size              = 30
  availability_zone = "${aws_instance.manager.availability_zone}"

  tags {
    Name = "docker-storage-${var.run_identifier}-manager"
  }
}

resource "aws_volume_attachment" "manager_storage_attachment" {
  device_name  = "/dev/sdh"
  force_detach = true
  volume_id    = "${aws_ebs_volume.manager_storage.id}"
  instance_id  = "${aws_instance.manager.id}"
}
