#!/usr/bin/env bash
# EWB Courses - AWS VPC Peering lab (Project 01) - AWS CLI builder
# Usage: STUDENT=yourname ./ewb-vpc-peering.sh <build|baseline|peer|show|test|fail|cleanup>
# Run on your laptop (WSL/macOS/Linux) with AWS CLI v2 logged in to your LAB account.
set -euo pipefail

REGION="${AWS_REGION:-ap-south-1}"
export AWS_DEFAULT_REGION="$REGION"
STUDENT="${STUDENT:?set STUDENT=yourname (no spaces)}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"

STATE="$HOME/.ewb-state.env"
EVID="$HOME/ewb-evidence"
KEY="$HOME/.ssh/ewb-lab.pem"
SSHCFG="$HOME/.ssh/ewb-lab-config"
mkdir -p "$EVID" "$HOME/.ssh"
touch "$STATE"
# shellcheck disable=SC1090
source "$STATE"

save() { echo "export $1=\"$2\"" >> "$STATE"; eval "$1=\"$2\""; }
tags() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=Project,Value=EWB-VPC-Peering},{Key=Student,Value=$STUDENT}]"; }
on() { ssh -F "$SSHCFG" "$@"; }
ICMP_FROM_A='IpProtocol=icmp,FromPort=8,ToPort=0,IpRanges=[{CidrIp=10.10.2.10/32}]'

build() {
  echo ">> Page 5-6: VPCs, subnets, IGW, route tables"
  AZ=$(aws ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text)
  save AZ "$AZ"
  MYIP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')

  save VPC_A "$(aws ec2 create-vpc --cidr-block 10.10.0.0/16 --tag-specifications "$(tags vpc ewb-vpc-a)" --query Vpc.VpcId --output text)"
  save VPC_B "$(aws ec2 create-vpc --cidr-block 10.20.0.0/16 --tag-specifications "$(tags vpc ewb-vpc-b)" --query Vpc.VpcId --output text)"

  save SUB_A_PUB  "$(aws ec2 create-subnet --vpc-id "$VPC_A" --cidr-block 10.10.1.0/24 --availability-zone "$AZ" --tag-specifications "$(tags subnet ewb-a-public)"  --query Subnet.SubnetId --output text)"
  save SUB_A_PRIV "$(aws ec2 create-subnet --vpc-id "$VPC_A" --cidr-block 10.10.2.0/24 --availability-zone "$AZ" --tag-specifications "$(tags subnet ewb-a-private)" --query Subnet.SubnetId --output text)"
  save SUB_B_PRIV "$(aws ec2 create-subnet --vpc-id "$VPC_B" --cidr-block 10.20.1.0/24 --availability-zone "$AZ" --tag-specifications "$(tags subnet ewb-b-private)" --query Subnet.SubnetId --output text)"

  save IGW "$(aws ec2 create-internet-gateway --tag-specifications "$(tags internet-gateway ewb-igw-a)" --query InternetGateway.InternetGatewayId --output text)"
  aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_A"

  save RT_A_PUB  "$(aws ec2 create-route-table --vpc-id "$VPC_A" --tag-specifications "$(tags route-table ewb-rt-a-public)"  --query RouteTable.RouteTableId --output text)"
  save RT_A_PRIV "$(aws ec2 create-route-table --vpc-id "$VPC_A" --tag-specifications "$(tags route-table ewb-rt-a-private)" --query RouteTable.RouteTableId --output text)"
  save RT_B_PRIV "$(aws ec2 create-route-table --vpc-id "$VPC_B" --tag-specifications "$(tags route-table ewb-rt-b-private)" --query RouteTable.RouteTableId --output text)"

  save ASSOC_A_PUB  "$(aws ec2 associate-route-table --route-table-id "$RT_A_PUB"  --subnet-id "$SUB_A_PUB"  --query AssociationId --output text)"
  save ASSOC_A_PRIV "$(aws ec2 associate-route-table --route-table-id "$RT_A_PRIV" --subnet-id "$SUB_A_PRIV" --query AssociationId --output text)"
  save ASSOC_B_PRIV "$(aws ec2 associate-route-table --route-table-id "$RT_B_PRIV" --subnet-id "$SUB_B_PRIV" --query AssociationId --output text)"
  aws ec2 create-route --route-table-id "$RT_A_PUB" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW" >/dev/null

  echo ">> Page 6: security groups"
  save SG_BASTION "$(aws ec2 create-security-group --group-name ewb-sg-bastion --description "EWB bastion" --vpc-id "$VPC_A" --tag-specifications "$(tags security-group ewb-sg-bastion)" --query GroupId --output text)"
  save SG_APP_A   "$(aws ec2 create-security-group --group-name ewb-sg-app-a   --description "EWB app A"   --vpc-id "$VPC_A" --tag-specifications "$(tags security-group ewb-sg-app-a)"   --query GroupId --output text)"
  save SG_APP_B   "$(aws ec2 create-security-group --group-name ewb-sg-app-b   --description "EWB app B"   --vpc-id "$VPC_B" --tag-specifications "$(tags security-group ewb-sg-app-b)"   --query GroupId --output text)"

  aws ec2 authorize-security-group-ingress --group-id "$SG_BASTION" --protocol tcp --port 22 --cidr "$MYIP/32" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$SG_APP_A" --protocol tcp --port 22 --cidr 10.10.1.10/32 >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$SG_APP_A" --ip-permissions 'IpProtocol=icmp,FromPort=8,ToPort=0,IpRanges=[{CidrIp=10.20.1.10/32}]' >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$SG_APP_B" --protocol tcp --port 22 --cidr 10.10.1.10/32 >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$SG_APP_B" --ip-permissions "$ICMP_FROM_A" >/dev/null

  echo ">> Page 7: key pair + instances"
  if [ ! -f "$KEY" ]; then
    ( umask 077; aws ec2 create-key-pair --key-name ewb-lab --key-type rsa --key-format pem \
        --tag-specifications "$(tags key-pair ewb-lab)" --query KeyMaterial --output text > "$KEY" )
    chmod 400 "$KEY"
  fi

  AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)
  launch() { # name subnet sg private-ip public(true|false)
    aws ec2 run-instances --image-id "$AMI" --instance-type "$INSTANCE_TYPE" --key-name ewb-lab \
      --network-interfaces "DeviceIndex=0,SubnetId=$2,Groups=$3,PrivateIpAddress=$4,AssociatePublicIpAddress=$5" \
      --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=8,VolumeType=gp3,DeleteOnTermination=true}" \
      --tag-specifications "$(tags instance "$1")" "$(tags volume "$1")" \
      --query 'Instances[0].InstanceId' --output text
  }
  save I_BASTION "$(launch ewb-bastion  "$SUB_A_PUB"  "$SG_BASTION" 10.10.1.10 true)"
  save I_APP_A   "$(launch ewb-app-a    "$SUB_A_PRIV" "$SG_APP_A"   10.10.2.10 false)"
  save I_APP_B   "$(launch ewb-app-b    "$SUB_B_PRIV" "$SG_APP_B"   10.20.1.10 false)"

  echo ">> waiting for status checks (few minutes)..."
  aws ec2 wait instance-status-ok --instance-ids "$I_BASTION" "$I_APP_A" "$I_APP_B"

  BASTION_IP=$(aws ec2 describe-instances --instance-ids "$I_BASTION" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  save BASTION_IP "$BASTION_IP"

  echo ">> Page 8: SSH config -> $SSHCFG"
  cat > "$SSHCFG" <<EOF
Host ewb-bastion
    HostName $BASTION_IP
    User ec2-user
    IdentityFile $KEY
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new

Host ewb-app-a
    HostName 10.10.2.10
    User ec2-user
    IdentityFile $KEY
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ProxyJump ewb-bastion

Host ewb-app-b
    HostName 10.20.1.10
    User ec2-user
    IdentityFile $KEY
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ProxyJump ewb-bastion
EOF
  echo "BUILD DONE. Next: ./ewb-vpc-peering.sh baseline"
}

baseline() { # test 01 - must FAIL
  echo ">> Test 01 baseline (expect 100% loss)"
  on ewb-bastion 'hostname' | tee "$EVID/00-bastion-ssh.txt"
  { on ewb-app-a 'hostname; hostname -I; ping -c 4 -W 2 10.20.1.10 || true'; } | tee "$EVID/01-baseline.txt"
}

peer() {
  echo ">> Page 9: peering"
  save PCX "$(aws ec2 create-vpc-peering-connection --vpc-id "$VPC_A" --peer-vpc-id "$VPC_B" \
    --tag-specifications "$(tags vpc-peering-connection ewb-a-b-peer)" \
    --query VpcPeeringConnection.VpcPeeringConnectionId --output text)"
  aws ec2 wait vpc-peering-connection-exists --vpc-peering-connection-ids "$PCX"
  aws ec2 accept-vpc-peering-connection --vpc-peering-connection-id "$PCX" >/dev/null
  until [ "$(aws ec2 describe-vpc-peering-connections --vpc-peering-connection-ids "$PCX" \
        --query 'VpcPeeringConnections[0].Status.Code' --output text)" = "active" ]; do sleep 3; done

  echo ">> Page 10: routes on both sides"
  aws ec2 create-route --route-table-id "$RT_A_PRIV" --destination-cidr-block 10.20.0.0/16 --vpc-peering-connection-id "$PCX" >/dev/null
  aws ec2 create-route --route-table-id "$RT_B_PRIV" --destination-cidr-block 10.10.0.0/16 --vpc-peering-connection-id "$PCX" >/dev/null
  aws ec2 create-route --route-table-id "$RT_A_PUB"  --destination-cidr-block 10.20.0.0/16 --vpc-peering-connection-id "$PCX" >/dev/null
  echo "PEER DONE. Next: show, then test"
}

show() { # evidence for checkpoints 01, 03, 04 + SG rules
  {
    aws ec2 describe-vpc-peering-connections --vpc-peering-connection-ids "${PCX:-none}" \
      --query 'VpcPeeringConnections[].[Tags[0].Value,VpcPeeringConnectionId,Status.Code,RequesterVpcInfo.VpcId,AccepterVpcInfo.VpcId]' --output table 2>/dev/null || true
    for rt in "$RT_A_PUB" "$RT_A_PRIV" "$RT_B_PRIV"; do
      echo "== $rt"
      aws ec2 describe-route-tables --route-table-ids "$rt" \
        --query 'RouteTables[0].[Associations[].SubnetId,Routes[].[DestinationCidrBlock,GatewayId,VpcPeeringConnectionId]]' --output json
    done
    for sg in "$SG_BASTION" "$SG_APP_A" "$SG_APP_B"; do
      echo "== $sg"
      aws ec2 describe-security-groups --group-ids "$sg" \
        --query 'SecurityGroups[0].IpPermissions[].[IpProtocol,FromPort,ToPort,IpRanges[0].CidrIp]' --output table
    done
  } | tee "$EVID/show-config.txt"
}

test_all() {
  echo ">> Test 02 forward"; { on ewb-app-a 'hostname; hostname -I; ping -c 4 -W 2 10.20.1.10 || true'; } | tee "$EVID/02-forward.txt"
  echo ">> Test 03 reverse"; { on ewb-app-b 'hostname; hostname -I; ping -c 4 -W 2 10.10.2.10 || true'; } | tee "$EVID/03-reverse.txt"
  echo ">> Test 04 private SSH"; on ewb-app-b 'hostname; hostname -I' | tee "$EVID/04-ssh-app-b.txt"
  echo ">> Test 05 isolation (expect None)"
  aws ec2 describe-instances --instance-ids "$I_APP_A" "$I_APP_B" \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,PrivateIpAddress,PublicIpAddress]' --output table | tee "$EVID/05-isolation.txt"
}

fail_test() { # controlled failure: drop ICMP rule on App-B, then restore
  echo ">> remove ICMP rule on ewb-sg-app-b"
  aws ec2 revoke-security-group-ingress --group-id "$SG_APP_B" --ip-permissions "$ICMP_FROM_A" >/dev/null
  { on ewb-app-a 'echo FAIL-TEST; ping -c 4 -W 2 10.20.1.10 || true'; } | tee "$EVID/06-controlled-failure.txt"
  echo ">> restore exact rule"
  aws ec2 authorize-security-group-ingress --group-id "$SG_APP_B" --ip-permissions "$ICMP_FROM_A" >/dev/null
  sleep 5
  { on ewb-app-a 'echo RECOVERY; ping -c 4 -W 2 10.20.1.10 || true'; } | tee "$EVID/07-recovery.txt"
}

cleanup() {
  d() { "$@" >/dev/null 2>&1 || echo "skip: $*"; }
  ids=$(aws ec2 describe-instances --filters Name=tag:Project,Values=EWB-VPC-Peering \
        Name=instance-state-name,Values=pending,running,stopping,stopped \
        --query 'Reservations[].Instances[].InstanceId' --output text)
  if [ -n "$ids" ]; then
    aws ec2 terminate-instances --instance-ids $ids >/dev/null
    aws ec2 wait instance-terminated --instance-ids $ids
  fi
  d aws ec2 delete-key-pair --key-name ewb-lab
  rm -f "$KEY" "$SSHCFG"
  d aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "${PCX:-none}"
  sleep 5
  for sg in "${SG_BASTION:-none}" "${SG_APP_A:-none}" "${SG_APP_B:-none}"; do d aws ec2 delete-security-group --group-id "$sg"; done
  for a in "${ASSOC_A_PUB:-none}" "${ASSOC_A_PRIV:-none}" "${ASSOC_B_PRIV:-none}"; do d aws ec2 disassociate-route-table --association-id "$a"; done
  for rt in "${RT_A_PUB:-none}" "${RT_A_PRIV:-none}" "${RT_B_PRIV:-none}"; do d aws ec2 delete-route-table --route-table-id "$rt"; done
  for s in "${SUB_A_PUB:-none}" "${SUB_A_PRIV:-none}" "${SUB_B_PRIV:-none}"; do d aws ec2 delete-subnet --subnet-id "$s"; done
  d aws ec2 detach-internet-gateway --internet-gateway-id "${IGW:-none}" --vpc-id "${VPC_A:-none}"
  d aws ec2 delete-internet-gateway --internet-gateway-id "${IGW:-none}"
  d aws ec2 delete-vpc --vpc-id "${VPC_A:-none}"
  d aws ec2 delete-vpc --vpc-id "${VPC_B:-none}"
  echo ">> leftover check (should be empty):"
  aws ec2 describe-vpcs --filters Name=tag:Project,Values=EWB-VPC-Peering --query 'Vpcs[].VpcId' --output text | tee "$EVID/99-cleanup.txt"
  aws ec2 describe-volumes --filters Name=tag:Project,Values=EWB-VPC-Peering --query 'Volumes[].VolumeId' --output text | tee -a "$EVID/99-cleanup.txt"
  mv "$STATE" "$STATE.done" 2>/dev/null || true
  echo "CLEANUP DONE. Also check Billing page later."
}

case "${1:-}" in
  build) build ;;
  baseline) baseline ;;
  peer) peer ;;
  show) show ;;
  test) test_all ;;
  fail) fail_test ;;
  cleanup) cleanup ;;
  *) echo "usage: STUDENT=name $0 build|baseline|peer|show|test|fail|cleanup"; exit 1 ;;
esac
