#!/usr/bin/env bash

set -o pipefail
set -o nounset
set -o errexit
IFS=$'\n\t'

################################################################################
### Validate Required Arguments ################################################
################################################################################
validate_env_set() {
  (
    set +o nounset

    if [ -z "${!1}" ]; then
      echo "Packer variable '$1' was not set. Aborting"
      exit 1
    fi
  )
}

validate_env_set WORKING_DIR
validate_env_set KUBERNETES_VERSION
validate_env_set CACHE_SHIFT_CONTAINER_IMAGES

################################################################################
### SHIFT CA cert ##############################################################
################################################################################

echo "Downloading the SHIFT CA certificate"

sudo mv $WORKING_DIR/shift-ca.pem /etc/pki/ca-trust/source/anchors/
sudo chown root:root /etc/pki/ca-trust/source/anchors/shift-ca.pem
sudo update-ca-trust --extract

################################################################################
### IMDS emulator ##############################################################
################################################################################

echo "Configuring the IMDS emulator"

sudo mv $WORKING_DIR/imds-emulator.service /etc/systemd/system/imds-emulator.service
sudo chown root:root /etc/systemd/system/imds-emulator.service
sudo systemctl enable imds-emulator.service
sudo systemctl start imds-emulator.service


cat << EOF | sudo tee /etc/systemd/system/containerd.service.d/50-shift-imds.conf
[Service]
Environment='AWS_EC2_METADATA_SERVICE_ENDPOINT=http://localhost:1338'
EOF

cat << EOF | sudo tee /etc/systemd/system/kubelet.service.d/50-shift-imds.conf
[Service]
Environment='AWS_EC2_METADATA_SERVICE_ENDPOINT=http://localhost:1338'
EOF

################################################################################
### Cache Images ###############################################################
################################################################################

if [[ "$CACHE_SHIFT_CONTAINER_IMAGES" == "true" ]]; then
  echo "Caching SHIFT container images"

  AWS_DOMAIN=$(imds 'latest/meta-data/services/domain')
  AWS_ACCOUNT_ID=$(imds 'latest/dynamic/instance-identity/document' | jq -r .accountId)
  ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.${AWS_DOMAIN}"

  sudo systemctl daemon-reload
  sudo systemctl start containerd
  sudo systemctl enable containerd

  K8S_MINOR_VERSION=$(echo "${KUBERNETES_VERSION}" | cut -d'.' -f1-2)

  #### Cache VPC CNI images starting with the addon default version and the latest version
  VPC_CNI_ADDON_VERSIONS=$(aws eks describe-addon-versions --addon-name vpc-cni --kubernetes-version=${K8S_MINOR_VERSION})
  VPC_CNI_IMGS=()
  if [[ $(jq '.addons | length' <<< $VPC_CNI_ADDON_VERSIONS) -gt 0 ]]; then
    DEFAULT_VPC_CNI_VERSION=$(echo "${VPC_CNI_ADDON_VERSIONS}" | jq -r '.addons[] .addonVersions[] | select(.compatibilities[] .defaultVersion==true).addonVersion')
    LATEST_VPC_CNI_VERSION=$(echo "${VPC_CNI_ADDON_VERSIONS}" | jq -r '.addons[] .addonVersions[] .addonVersion' | sort -V | tail -n1)
    CNI_IMG="${ECR_URI}/amazon-k8s-cni"
    CNI_INIT_IMG="${CNI_IMG}-init"

    VPC_CNI_IMGS=(
      ## Default VPC CNI Images
      "${CNI_IMG}:${DEFAULT_VPC_CNI_VERSION}"
      "${CNI_INIT_IMG}:${DEFAULT_VPC_CNI_VERSION}"

      ## Latest VPC CNI Images
      "${CNI_IMG}:${LATEST_VPC_CNI_VERSION}"
      "${CNI_INIT_IMG}:${LATEST_VPC_CNI_VERSION}"
    )
  fi

  CACHE_IMGS=(
    ${VPC_CNI_IMGS[@]:-}
  )
  PULLED_IMGS=()
  REGIONS=$(aws ec2 describe-regions --all-regions --output text --query 'Regions[].[RegionName]')

  for img in "${CACHE_IMGS[@]:-}"; do
    ## Since eksbuild.x version may not match the image tag, we need to decrement the eksbuild version until we find the latest image tag within the app semver
    eksbuild_version="1"
    if [[ ${img} == *'eksbuild.'* ]]; then
      eksbuild_version=$(echo "${img}" | grep -o 'eksbuild\.[0-9]\+' | cut -d'.' -f2)
    fi
    ## iterate through decrementing the build version each time
    for build_version in $(seq "${eksbuild_version}" -1 1); do
      img=$(echo "${img}" | sed -E "s/eksbuild.[0-9]+/eksbuild.${build_version}/")
      if /etc/eks/containerd/pull-image.sh "${img}"; then
        PULLED_IMGS+=("${img}")
        break
      elif [[ "${build_version}" -eq 1 ]]; then
        exit 1
      fi
    done
  done

  #### Tag the pulled down image for all other regions in the partition
  for region in ${REGIONS[*]}; do
    for img in "${PULLED_IMGS[@]:-}"; do
      region_uri=$(/etc/eks/get-ecr-uri.sh "${region}" "${AWS_DOMAIN}")
      regional_img="${img/$ECR_URI/$region_uri}"
      sudo ctr -n k8s.io image tag "${img}" "${regional_img}" || :
      ## Tag ECR fips endpoint for supported regions
      if [[ "${region}" =~ (us-east-1|us-east-2|us-west-1|us-west-2|us-gov-east-1|us-gov-west-1) ]]; then
        regional_fips_img="${regional_img/.ecr./.ecr-fips.}"
        sudo ctr -n k8s.io image tag "${img}" "${regional_fips_img}" || :
        sudo ctr -n k8s.io image tag "${img}" "${regional_fips_img/-eksbuild.1/}" || :
      fi
      ## Cache the non-addon VPC CNI images since "v*.*.*-eksbuild.1" is equivalent to leaving off the eksbuild suffix
      if [[ "${img}" == *"-cni"*"-eksbuild.1" ]]; then
        sudo ctr -n k8s.io image tag "${img}" "${regional_img/-eksbuild.1/}" || :
      fi
    done
  done
fi