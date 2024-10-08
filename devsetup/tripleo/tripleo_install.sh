#!/bin/bash
#
# Copyright 2023 Red Hat Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.
set -ex

openstack undercloud install
source stackrc

openstack overcloud network provision --output network_provision_out.yaml ./network_data.yaml
openstack overcloud network vip provision --stack overcloud --output vips_provision_out.yaml ./vips_data.yaml

# check if hostnamemap contains networkers
networker_nodes="FALSE"
config_download="config-download.yaml"
if (grep -q networker hostnamemap.yaml); then
    networker_nodes="TRUE"
    config_download="config-download-networker.yaml"
fi

# update the config-download with proper overcloud hostnames
control0=$(grep "overcloud-controller-0" hostnamemap.yaml  | awk '{print $2}')
control1=$(grep "overcloud-controller-1" hostnamemap.yaml  | awk '{print $2}')
control2=$(grep "overcloud-controller-2" hostnamemap.yaml  | awk '{print $2}')
sed -i "s/controller-0/${control0}/" $config_download
sed -i "s/controller-1/${control1}/" $config_download
sed -i "s/controller-2/${control2}/" $config_download
compute0=$(grep "overcloud-novacompute-0" hostnamemap.yaml  | awk '{print $2}')
compute1=$(grep "overcloud-novacompute-1" hostnamemap.yaml  | awk '{print $2}')
sed -i "s/compute-0/${compute0}/" $config_download
sed -i "s/compute-1/${compute1}/" $config_download

if [ $networker_nodes == "FALSE" ]; then
    compute2=$(grep "overcloud-novacompute-2" hostnamemap.yaml  | awk '{print $2}')
    sed -i "s/compute-2/${compute2}/" $config_download
elif [ $networker_nodes == "TRUE" ]; then
    networker0=$(grep "overcloud-networker-0" hostnamemap.yaml  | awk '{print $2}')
    networker1=$(grep "overcloud-networker-1" hostnamemap.yaml  | awk '{print $2}')
    sed -i "s/networker-0/${networker0}/" $config_download
    sed -i "s/networker-1/${networker1}/" $config_download
fi

if [ "$EDPM_COMPUTE_CEPH_ENABLED" == "true"  ] ; then
    # use default role name for ComputeHCI in hostnamemap
    sed -i "s/-novacompute-/-computehci-/" hostnamemap.yaml
    # read all the contents of hostnamemap except the yaml separator into one line
    hostnamemap=$(grep -v "\---" hostnamemap.yaml | tr '\n' '\r')
    hostnamemap="$hostnamemap\r  ControllerHostnameFormat: '%stackname%-controller-%index%'\r"
    # add hci role for ceph nodes
    hostnamemap="$hostnamemap\r  ComputeHCIHostnameFormat: '%stackname%-computehci-%index%'"
    # insert hostnamemap contents into config-download.yaml, we need it to generate
    # the inventory for ceph deployment
    sed -i "s/parameter_defaults:/${hostnamemap}/" $config_download

    # swap computes for compute hci
    sed -i "s/::Compute::/::ComputeHCI::/" $config_download
    # add storage management port to compute hci nodes
    stg_line="OS::TripleO::ComputeHCI::Ports::StoragePort: /usr/share/openstack-tripleo-heat-templates/network/ports/deployed_storage.yaml"
    stg_mgmt_line="OS::TripleO::ComputeHCI::Ports::StorageMgmtPort: /usr/share/openstack-tripleo-heat-templates/network/ports/deployed_storage_mgmt.yaml"
    sed -i "s#$stg_line#$stg_line\r  $stg_mgmt_line\r#" $config_download
    # correct RoleCount var in overcloud_services
    sed -i "s/ComputeCount/ComputeHCICount/" overcloud_services.yaml
fi
# Remove any quotes e.g. "np10002"-ctlplane -> np10002-ctlplane
sed -i 's/\"//g' $config_download
# re-add newlines
sed -i "s/\r/\n/g" $config_download
# remove empty lines
sed -i "/^$/d" $config_download

# Add Manila bits
MANILA_ENABLED=${MANILA_ENABLED:-true}
if [ "$MANILA_ENABLED" = "true" ]; then
    ENV_ARGS+=" -e /usr/share/openstack-tripleo-heat-templates/environments/manila-cephfsnative-config.yaml"
fi
# Add octavia bits
OCTAVIA_ENABLED=${OCTAVIA_ENABLED:-false}
if [ "$OCTAVIA_ENABLED" = "true" ]; then
    ENV_ARGS+=" -e /usr/share/openstack-tripleo-heat-templates/environments/services/octavia.yaml"
fi

TELEMETRY_ENABLED=${TELEMETRY_ENABLED:-true}
if [ "$TELEMETRY_ENABLED" = "true" ]; then
    ENV_ARGS+=" -e /usr/share/openstack-tripleo-heat-templates/environments/enable-legacy-telemetry.yaml"
fi

# defaults for non-ceph case
CEPH_OVERCLOUD_ARGS=""
ROLES_FILE="/home/zuul/overcloud_roles.yaml"
if [ "$EDPM_COMPUTE_CEPH_ENABLED" == "true"  ] ; then
    CEPH_OVERCLOUD_ARGS="${CEPH_ARGS}"
    [[ "$MANILA_ENABLED" == "true" ]] && CEPH_OVERCLOUD_ARGS+=' -e /usr/share/openstack-tripleo-heat-templates/environments/cephadm/ceph-mds.yaml'
    ROLES_FILE="/home/zuul/roles.yaml"
    /tmp/ceph.sh
fi

openstack overcloud deploy --stack overcloud \
    --override-ansible-cfg /home/zuul/ansible_config.cfg --templates /usr/share/openstack-tripleo-heat-templates \
    --roles-file ${ROLES_FILE} -n /home/zuul/network_data.yaml --libvirt-type qemu \
    --ntp-server ${NTP_SERVER} \
    --timeout 90 --overcloud-ssh-user zuul --deployed-server \
    -e /home/zuul/hostnamemap.yaml -e /usr/share/openstack-tripleo-heat-templates/environments/docker-ha.yaml \
    -e /home/zuul/containers-prepare-parameters.yaml -e /usr/share/openstack-tripleo-heat-templates/environments/podman.yaml \
    -e /usr/share/openstack-tripleo-heat-templates/environments/low-memory-usage.yaml \
    -e /usr/share/openstack-tripleo-heat-templates/environments/debug.yaml --validation-warnings-fatal ${ENV_ARGS} ${CEPH_OVERCLOUD_ARGS} \
    -e /home/zuul/overcloud_services.yaml -e /home/zuul/$config_download \
    -e /home/zuul/vips_provision_out.yaml -e /home/zuul/network_provision_out.yaml --disable-validations --heat-type pod \
    --disable-protected-resource-types
