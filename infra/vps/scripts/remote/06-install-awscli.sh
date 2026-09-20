#!/usr/bin/env bash
# Install AWS CLI v2 (Ubuntu 24.04 has no awscli apt package).
set -euo pipefail

if command -v aws >/dev/null 2>&1; then
  aws --version
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y unzip curl
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update
rm -rf /tmp/aws /tmp/awscliv2.zip
aws --version
