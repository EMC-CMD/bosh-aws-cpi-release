#!/usr/bin/env bash

set -e

source bosh-cpi-src/ci/tasks/utils.sh

check_param aws_access_key_id
check_param aws_secret_access_key
check_param director_password
check_param director_username
check_param region_name
check_param stack_name
check_param stemcell_name

source /etc/profile.d/chruby.sh
chruby 2.1.2

export AWS_ACCESS_KEY_ID=${aws_access_key_id}
export AWS_SECRET_ACCESS_KEY=${aws_secret_access_key}
export AWS_DEFAULT_REGION=${region_name}

cpi_release_name="bosh-aws-cpi"
stack_info=$(get_stack_info $stack_name)

stack_prefix="End2End"
SUBNET_ID=$(get_stack_info_of "${stack_info}" "${stack_prefix}DynamicSubnetID")
AVAILABILITY_ZONE=$(get_stack_info_of "${stack_info}" "${stack_prefix}AvailabilityZone")
DIRECTOR_IP=$(get_stack_info_of "${stack_info}" "${stack_prefix}DirectorEIP")
IAM_INSTANCE_PROFILE=$(get_stack_info_of "${stack_info}" "End2EndIAMInstanceProfile")
ELB_NAME=$(get_stack_info_of "${stack_info}" "End2EndELB")

e2e_deployment_name=e2e-test
e2e_release_name=${e2e_deployment_name}-release
e2e_release_version=1.0.0
e2e_manifest_filename=${PWD}/e2e-manifest.yml
export E2E_CONFIG_FILENAME="${PWD}/e2e-config.json"
cat > "${E2E_CONFIG_FILENAME}" << EOF
{
  "director_ip": "${DIRECTOR_IP}",
  "manifest_filename": "${e2e_manifest_filename}",
  "director_username": "${director_username}",
  "director_password": "${director_password}",
  "stemcell": "$(echo ${PWD}/stemcell/*.tgz)",
  "release": "${PWD}/bosh-cpi-src/ci/assets/e2e-test-release/dev_releases/${e2e_deployment_name}/${e2e_deployment_name}-${e2e_release_version}.tgz",
  "deployment_name": "${e2e_deployment_name}"
}
EOF

cat > "${e2e_manifest_filename}" <<EOF
---
name: ${e2e_deployment_name}
director_uuid: replace-me

releases:
  - name: e2e-test
    version: latest

compilation:
  reuse_compilation_vms: true
  workers: 1
  network: private
  cloud_properties:
    instance_type: m3.medium
    availability_zone: ${AVAILABILITY_ZONE}

update:
  canaries: 1
  canary_watch_time: 30000-240000
  update_watch_time: 30000-600000
  max_in_flight: 3

resource_pools:
  - &default_resource_pool
    name: default
    stemcell:
      name: ${stemcell_name}
      version: latest
    network: private
    cloud_properties: &default_cloud_properties
      instance_type: m3.medium
      availability_zone: ${AVAILABILITY_ZONE}
  - <<: *default_resource_pool
    name: raw_ephemeral_pool
    cloud_properties:
      <<: *default_cloud_properties
      raw_instance_storage: true
  - <<: *default_resource_pool
    name: elb_registration_pool
    cloud_properties:
      <<: *default_cloud_properties
      elbs: [${ELB_NAME}]

networks:
  - name: private
    type: dynamic
    cloud_properties: {subnet: ${SUBNET_ID}}

jobs:
  - name: iam-instance-profile-test
    template: iam-instance-profile-test
    lifecycle: errand
    instances: 1
    resource_pool: default
    networks:
      - name: private
        default: [dns, gateway]
  - name: raw-ephemeral-disk-test
    template: raw-ephemeral-disk-test
    lifecycle: errand
    instances: 1
    resource_pool: raw_ephemeral_pool
    networks:
      - name: private
        default: [dns, gateway]
  - name: elb-registration-test
    template: elb-registration-test
    lifecycle: errand
    instances: 1
    resource_pool: elb_registration_pool
    networks:
      - name: private
        default: [dns, gateway]

properties:
  iam_instance_profile: ${IAM_INSTANCE_PROFILE}
  load_balancer_name: ${ELB_NAME}
  aws_region: ${region_name}
EOF

cat >> bosh-cpi-src/src/bosh_aws_cpi/spec/integration/Gemfile << EOF
source 'https://rubygems.org'

gem 'rspec'
gem 'rubysl-open3'
gem 'json'
gem 'bosh_cli'
EOF

pushd bosh-cpi-src/ci/assets/e2e-test-release
  bosh -n create release --force --with-tarball --name ${e2e_deployment_name} --version ${e2e_release_version}
popd

pushd bosh-cpi-src/src/bosh_aws_cpi/spec/integration
  bundle install
  bundle exec rspec --color --warnings e2e_spec.rb
popd
