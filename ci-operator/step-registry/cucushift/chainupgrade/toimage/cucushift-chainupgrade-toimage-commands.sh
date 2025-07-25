#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'FRC=$?; createUpgradeJunit; debug' EXIT TERM

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"
# After cluster is set up, ci-operator make KUBECONFIG pointing to the installed cluster,
# to make "oc registry login" interact with the build farm, set KUBECONFIG to empty,
# so that the credentials of the build farm registry can be saved in docker client config file.
# A direct connection is required while communicating with build-farm, instead of through proxy
KUBECONFIG="" oc --loglevel=8 registry login

# Print cv, failed node, co, mcp information for debug purpose
function debug() {
    if (( FRC != 0 )); then
        if [[ -n "${TARGET_MINOR_VERSION}" ]] && [[ "${TARGET_MINOR_VERSION}" -ge "16" ]] ; then
            echo -e "\n# oc adm upgrade status\n"
            env OC_ENABLE_CMD_UPGRADE_STATUS='true' oc adm upgrade status --details=all || true 
        fi
        echo -e "\n# oc get clusterversion/version -oyaml\n$(oc get clusterversion/version -oyaml)"
        echo -e "\n# oc get machineconfig\n$(oc get machineconfig)"
        echo -e "\n# Describing abnormal nodes...\n"
        oc get node --no-headers | awk '$2 != "Ready" {print $1}' | while read node; do echo -e "\n#####oc describe node ${node}#####\n$(oc describe node ${node})"; done
        echo -e "\n# Describing abnormal operators...\n"
        oc get co --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | while read co; do echo -e "\n#####oc describe co ${co}#####\n$(oc describe co ${co})"; done
        echo -e "\n# Describing abnormal mcp...\n"
        oc get machineconfigpools --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | while read mcp; do echo -e "\n#####oc describe mcp ${mcp}#####\n$(oc describe mcp ${mcp})"; done
    fi
}

# Explicitly set upgrade failure to operators
function check_failed_operator(){
    local latest_ver_in_history failing_status failing_operator failing_operators
    latest_ver_in_history=$(oc get clusterversion version -ojson|jq -r '.status.history[0].version')
    if [[ "${latest_ver_in_history}" != "${TARGET_VERSION}" ]]; then
        # Upgrade does not start, set it to CVO
        echo "Upgrade does not start, set UPGRADE_FAILURE_TYPE to cvo"
        export UPGRADE_FAILURE_TYPE="cvo"
    else
        failing_status=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "Failing").status')
        # Upgrade stuck at operators while failing=True, check from the operators reported in cv Failing condition
        if [[ ${failing_status} == "True" ]]; then
            failing_operator=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "Failing").message'|grep -oP 'operator \K.*?(?= is)') || true
            failing_operators=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "Failing").message'|grep -oP 'operators \K.*?(?= are)'|tr -d ',') || true
            failing_operators="${failing_operator} ${failing_operators}"
        elif [[ ${failing_status} == "Unknown" ]]; then
            failing_operators=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "Failing").message'|grep -oP 'waiting on \K.*?(?= over)'|tr -d ',') || true
        else
            failing_operators=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "Progressing").message'|grep -oP 'wait has exceeded 40 minutes for these operators: \K.*'|tr -d ',') || \
            failing_operators=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "Progressing").message'|grep -oP 'waiting up to 40 minutes on \K.*'|tr -d ',') || \
            failing_operators=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "Progressing").message'|grep -oP 'waiting on \K.*'|tr -d ',') || true
        fi
        if [[ -n "${failing_operators}" && "${failing_operators}" =~ [^[:space:]] ]]; then
            echo "Upgrade stuck, set UPGRADE_FAILURE_TYPE to ${failing_operators}"
            export UPGRADE_FAILURE_TYPE="${failing_operators}"
        fi
    fi
}

# Generate the Junit for upgrade
function createUpgradeJunit() {
    echo -e "\n# Generating the Junit for upgrade"
    local upg_report="${ARTIFACT_DIR}/junit_upgrade.xml"
    local cases_in_upgrade
    if (( FRC == 0 )); then
        # The cases are SLOs on the live cluster which may be a possible UPGRADE_FAILURE_TYPE
        local cases_from_available_operators upgrade_success_cases
        cases_from_available_operators=$(oc get co --no-headers|awk '{print $1}'|tr '\n' ' ' || true)
        upgrade_success_cases="${UPGRADE_FAILURE_TYPE} ${cases_from_available_operators} ${IMPLICIT_ENABLED_CASES}"
        upgrade_success_cases=$(echo ${upgrade_success_cases} | tr ' ' '\n'|sort -u|xargs)
        IFS=" " read -r -a cases_in_upgrade <<< "${upgrade_success_cases}"
        echo '<?xml version="1.0" encoding="UTF-8"?>' > "${upg_report}"
        echo "<testsuite name=\"cluster upgrade\" tests=\"${#cases_in_upgrade[@]}\" failures=\"0\">" >> "${upg_report}"
        for case in "${cases_in_upgrade[@]}"; do
            echo "  <testcase classname=\"cluster upgrade\" name=\"upgrade should succeed: ${case}\"/>" >> "${upg_report}"
        done
        echo '</testsuite>' >> "${upg_report}"
    else
        IFS=" " read -r -a cases_in_upgrade <<< "${UPGRADE_FAILURE_TYPE}"
        echo '<?xml version="1.0" encoding="UTF-8"?>' > "${upg_report}"
        echo "<testsuite name=\"cluster upgrade\" tests=\"${#cases_in_upgrade[@]}\" failures=\"${#cases_in_upgrade[@]}\">" >> "${upg_report}"
        for case in "${cases_in_upgrade[@]}"; do
            echo "  <testcase classname=\"cluster upgrade\" name=\"upgrade should succeed: ${case}\">" >> "${upg_report}"
            echo "    <failure message=\"openshift cluster upgrade failed at ${case}\"></failure>" >> "${upg_report}"
            echo "  </testcase>" >> "${upg_report}"
        done
        echo '</testsuite>' >> "${upg_report}"
    fi
}

function extract_ccoctl(){
    local payload_image image_arch cco_image
    local retry=5
    local tmp_ccoctl="/tmp/upgtool"
    mkdir -p ${tmp_ccoctl}
    export PATH=/tmp:${PATH}
                
    echo -e "Extracting ccoctl\n"
    payload_image="${TARGET}"
    set -x          
    image_arch=$(oc adm release info ${payload_image} -a "${CLUSTER_PROFILE_DIR}/pull-secret" -o jsonpath='{.config.architecture}')
    if [[ "${image_arch}" == "arm64" ]]; then
        echo "The target payload is arm64 arch, trying to find out a matched version of payload image on amd64"
        if [[ -n ${RELEASE_IMAGE_TARGET:-} ]]; then
            payload_image=${RELEASE_IMAGE_TARGET}
            echo "Getting target release image from RELEASE_IMAGE_TARGET: ${payload_image}"
        elif env "NO_PROXY=*" "no_proxy=*" "KUBECONFIG=" oc get istag "release:target" -n ${NAMESPACE} &>/dev/null; then
            payload_image=$(env "NO_PROXY=*" "no_proxy=*" "KUBECONFIG=" oc -n ${NAMESPACE} get istag "release:target" -o jsonpath='{.tag.from.name}')
            echo "Getting target release image from build farm imagestream: ${payload_image}"
        fi 
    fi  
    set +x  
    cco_image=$(oc adm release info --image-for='cloud-credential-operator' ${payload_image} -a "${CLUSTER_PROFILE_DIR}/pull-secret") || return 1
    while ! (env "NO_PROXY=*" "no_proxy=*" oc image extract $cco_image --path="/usr/bin/ccoctl:${tmp_ccoctl}" -a "${CLUSTER_PROFILE_DIR}/pull-secret");
    do
        echo >&2 "Failed to extract ccoctl binary, retry..."
        (( retry -= 1 ))
        if (( retry < 0 )); then return 1; fi
        sleep 60
    done
    mv ${tmp_ccoctl}/ccoctl /tmp -f
    if [[ ! -e /tmp/ccoctl ]]; then
        echo "No ccoctl tool found!" && return 1
    else
        chmod 775 /tmp/ccoctl
    fi
    export PATH="$PATH"
}

function update_cloud_credentials_oidc(){
    local platform preCredsDir tobeCredsDir tmp_ret testcase="OCP-66839"

    platform=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}')
    preCredsDir="/tmp/pre-include-creds"
    tobeCredsDir="/tmp/tobe-include-creds"
    mkdir "${preCredsDir}" "${tobeCredsDir}"
    export IMPLICIT_ENABLED_CASES="${IMPLICIT_ENABLED_CASES} ${testcase}"
    # Extract all CRs from live cluster with --included
    if ! oc adm release extract --to "${preCredsDir}" --included --credentials-requests; then
        echo "Failed to extract CRs from live cluster!"
        export UPGRADE_FAILURE_TYPE="${testcase}"
        return 1
    fi
    if ! oc adm release extract --to "${tobeCredsDir}" --included --credentials-requests "${TARGET}"; then
        echo "Failed to extract CRs from tobe upgrade release payload!"
        export UPGRADE_FAILURE_TYPE="${testcase}"
        return 1
    fi

    # TODO: add gcp and azure
    # Update iam role with ccoctl based on tobeCredsDir
    tmp_ret=0
    diff -r "${preCredsDir}" "${tobeCredsDir}" || tmp_ret=1
    if [[ ${tmp_ret} != 0 ]]; then
        toManifests="/tmp/to-manifests"
        mkdir "${toManifests}"
        case "${platform}" in
        "AWS")
            if [[ ! -e ${SHARED_DIR}/aws_oidc_provider_arn ]]; then
		echo "No aws_oidc_provider_arn file in SHARED_DIR"
		return 1
            else
                export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
                infra_name=${NAMESPACE}-${UNIQUE_HASH}
                oidc_provider=$(head -n1 ${SHARED_DIR}/aws_oidc_provider_arn)
                extract_ccoctl || { export UPGRADE_FAILURE_TYPE="cloud-credential"; return 1; }
                if ! ccoctl aws create-iam-roles --name="${infra_name}" --region="${LEASED_RESOURCE}" --credentials-requests-dir="${tobeCredsDir}" --identity-provider-arn="${oidc_provider}" --output-dir="${toManifests}"; then
		    echo "Failed to update iam role!"
		    export UPGRADE_FAILURE_TYPE="cloud-credential"
		    return 1
                fi
                if [[ "$(ls -A ${toManifests}/manifests)" ]]; then
                    echo "Apply the new credential secrets."
                    oc apply -f "${toManifests}/manifests"
                fi
            fi
            ;;
        *)
            echo "to be supported platform: ${platform}"
            ;;
        esac
    fi
}

# Add cloudcredential.openshift.io/upgradeable-to: <version_number> to cloudcredential cluster when cco mode is manual
function cco_annotation(){
    local source_version="${1}" target_version="${2}" source_minor_version target_minor_version
    source_minor_version="$(echo "$source_version" | cut -f2 -d.)"
    target_minor_version="$(echo "$target_version" | cut -f2 -d.)"
    if (( source_minor_version == target_minor_version )) || (( source_minor_version < 8 )); then
        echo "CCO annotation change is not required in either z-stream upgrade or 4.7 and earlier" && return
    fi

    local cco_mode; cco_mode="$(oc get cloudcredential cluster -o jsonpath='{.spec.credentialsMode}')"
    local platform; platform="$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}')"
    if [[ ${cco_mode} == "Manual" ]]; then
        echo "CCO annotation change is required in Manual mode"
    elif [[ -z "${cco_mode}" || ${cco_mode} == "Mint" ]]; then
        if [[ "${source_minor_version}" == "14" && ${platform} == "GCP" ]] ; then
            echo "CCO annotation change is required in default or Mint mode on 4.14 GCP cluster"
        else
            echo "CCO annotation change is not required in default or Mint mode on 4.${source_minor_version} ${platform} cluster"
            return 0
        fi
    else
        echo "CCO annotation change is not required in ${cco_mode} mode"
        return 0
    fi

    echo "Require CCO annotation change"
    local wait_time_loop_var=0; to_version="$(echo "${target_version}" | cut -f1 -d-)"
    oc patch cloudcredential.operator.openshift.io/cluster --patch '{"metadata":{"annotations": {"cloudcredential.openshift.io/upgradeable-to": "'"${to_version}"'"}}}' --type=merge

    echo "CCO annotation patch gets started"

    echo -e "sleep 5 min wait CCO annotation patch to be valid...\n"
    while (( wait_time_loop_var < 5 )); do
        sleep 1m
        echo -e "wait_time_passed=${wait_time_loop_var} min.\n"
        if ! oc adm upgrade | grep "MissingUpgradeableAnnotation"; then
            echo -e "CCO annotation patch PASSED\n"
            return 0
        else
            echo -e "CCO annotation patch still in processing, waiting...\n"
        fi
        (( wait_time_loop_var += 1 ))
    done
    if (( wait_time_loop_var >= 5 )); then
        echo >&2 "Timed out waiting for CCO annotation completing, exiting"
        # Explicitly set failure to cco
        export UPGRADE_FAILURE_TYPE="cloud-credential"
        return 1
    fi
}

function disable_boot_image_update() {
    # Get current machineManagers value
    local current_value
    current_value=$(oc get MachineConfiguration cluster -n openshift-machine-config-operator -o jsonpath='{.spec.managedBootImages.machineManagers}' 2>/dev/null)
    local get_status=$?

    if [ $get_status -ne 0 ]; then
        echo "Error: Failed to get current MachineConfiguration. Check cluster access."
	export UPGRADE_FAILURE_TYPE="machine-config"
        return 1
    fi

    # Check if the value is already empty array
    if [[ "$current_value" == "[]" ]]; then
        echo "machineManagers is already configured as empty array. No changes needed."
        return 0
    fi

    echo "Current machineManagers value: $current_value"
    echo "Disabling updated boot images by editing MachineConfiguration..."
    # Edit the MachineConfiguration to disable boot image updates
    if ! oc patch MachineConfiguration cluster --type=merge --patch '{"spec":{"managedBootImages":{"machineManagers":[]}}}' -n openshift-machine-config-operator; then
        echo "Error: Failed to patch MachineConfiguration."
	export UPGRADE_FAILURE_TYPE="machine-config"
        return 1
    fi

    # Verify the change
    echo "Verifying the change..."
    local new_value
    new_value=$(oc get MachineConfiguration cluster -n openshift-machine-config-operator -o jsonpath='{.spec.managedBootImages.machineManagers}')

    if [[ "$new_value" == "[]" ]]; then
        echo "Successfully disabled boot image update."
        return 0
    else
        echo "Error: Failed to update machineManagers. Current value: $new_value"
	export UPGRADE_FAILURE_TYPE="machine-config"
        return 1
    fi
}

# Update RHEL repo before upgrade
function rhel_repo(){
    echo "Updating RHEL node repo"
    # Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
    # to be able to SSH.
    local testcase="rhel"
    export IMPLICIT_ENABLED_CASES="${IMPLICIT_ENABLED_CASES} ${testcase}"
    if ! whoami &> /dev/null; then
        if [[ -w /etc/passwd ]]; then
            echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
        else
            echo "/etc/passwd is not writeable, and user matching this uid is not found."
            # Explicitly set failure to rhel for rhel worker upgrade failure
            export UPGRADE_FAILURE_TYPE="${testcase}"
            exit 1
        fi
    fi
    SOURCE_REPO_VERSION=$(echo "${SOURCE_VERSION}" | cut -d'.' -f1,2)
    TARGET_REPO_VERSION=$(echo "${TARGET_VERSION}" | cut -d'.' -f1,2)
    export SOURCE_REPO_VERSION
    export TARGET_REPO_VERSION

    cat > /tmp/repo.yaml <<-'EOF'
---
- name: Update repo Playbook
  hosts: workers
  any_errors_fatal: true
  gather_facts: false
  vars:
    source_repo_version: "{{ lookup('env', 'SOURCE_REPO_VERSION') }}"
    target_repo_version: "{{ lookup('env', 'TARGET_REPO_VERSION') }}"
    platform_version: "{{ lookup('env', 'PLATFORM_VERSION') }}"
    major_platform_version: "{{ platform_version[:1] }}"
  tasks:
  - name: Wait for host connection to ensure SSH has started
    wait_for_connection:
      timeout: 600
  - name: Replace source release version with target release version in the files
    replace:
      path: "/etc/yum.repos.d/rhel-{{ major_platform_version }}-server-ose-rpms.repo"
      regexp: "{{ source_repo_version }}"
      replace: "{{ target_repo_version }}"
  - name: Clean up yum cache
    command: yum clean all
EOF

    # current Server version may not be the expected branch when cluster is not fully upgraded 
    # using TARGET_REPO_VERSION instead directly
    version_info="${TARGET_REPO_VERSION}"
    openshift_ansible_branch='master'
    if [[ "$version_info" =~ [4-9].[0-9]+ ]] ; then
        openshift_ansible_branch="release-${version_info}"
        minor_version="${version_info##*.}"
        if [[ -n "$minor_version" ]] && [[ $minor_version -le 10 ]] ; then
            source /opt/python-env/ansible2.9/bin/activate
        else
            source /opt/python-env/ansible-core/bin/activate
        fi
        ansible --version
    else
        echo "WARNING: version_info is $version_info"
    fi
    echo -e "Using openshift-ansible branch $openshift_ansible_branch\n"
    cd /usr/share/ansible/openshift-ansible
    git stash || true
    git checkout "$openshift_ansible_branch"
    git pull || true
    ansible-inventory -i "${SHARED_DIR}/ansible-hosts" --list --yaml
    ansible-playbook -i "${SHARED_DIR}/ansible-hosts" /tmp/repo.yaml -vvv
}

function rhel_pre_unpause(){
    echo "Running the workaround step before unpausing worker mcp"
    local testcase="rhel"
    cat > /tmp/rhel_pre_unpause.yaml <<-'EOF'
---
- name: RHEL pre-unpause playbook
  hosts: workers
  any_errors_fatal: true
  gather_facts: false
  vars:
    required_packages:
      - ose-azure-acr-image-credential-provider
      - ose-gcp-gcr-image-credential-provider
  tasks:
  - name: Install required package on the node
    dnf:
      name: "{{ required_packages }}"
      state: latest
      disable_gpg_check: true
EOF
    ansible-inventory -i "${SHARED_DIR}/ansible-hosts" --list --yaml
    ansible-playbook -i "${SHARED_DIR}/ansible-hosts" /tmp/rhel_pre_unpause.yaml -vvv
}

# Do sdn migration to ovn since sdn is not supported from 4.17 version
function sdn2ovn(){
    oc patch network.operator.openshift.io cluster --type='merge'  -p='{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"ipv4":{"internalJoinSubnet": "100.65.0.0/16"}}}}}' 
    oc patch network.operator.openshift.io cluster --type='merge'  -p='{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"ipv4":{"internalTransitSwitchSubnet": "100.85.0.0/16"}}}}}' 
    oc patch Network.config.openshift.io cluster --type='merge' --patch '{"metadata":{"annotations":{"network.openshift.io/network-type-migration":""}},"spec":{"networkType":"OVNKubernetes"}}'
    timeout 300s bash <<EOT
    until 
       oc get network -o yaml | grep NetworkTypeMigrationInProgress > /dev/null
    do
       echo "Migration is not started yet"
       sleep 10
    done
EOT
    echo "Start Live Migration process now"
    # Wait for the live migration to fully complete
    timeout 3600s bash <<EOT
    until 
       oc get network -o yaml | grep NetworkTypeMigrationCompleted > /dev/null && \
       for NODE in \$(oc get nodes -o custom-columns=NAME:.metadata.name --no-headers); do oc get node \$NODE -o yaml | grep "k8s.ovn.org/node-transit-switch-port-ifaddr:" | grep "100.85";  done > /dev/null && \
       for NODE in \$(oc get nodes -o custom-columns=NAME:.metadata.name --no-headers); do oc get node \$NODE -o yaml | grep "k8s.ovn.org/node-gateway-router-lrp-ifaddr:" | grep "100.65";  done > /dev/null && \
       oc get network.config/cluster -o jsonpath='{.status.networkType}' | grep OVNKubernetes > /dev/null;
    do
       echo "Live migration is still in progress"
       sleep 300
    done
EOT
    echo "The Migration is completed"
}

# Upgrade RHEL node
function rhel_upgrade(){
    echo "Upgrading RHEL nodes"
    echo "Validating parsed Ansible inventory"
    local testcase="rhel"
    ansible-inventory -i "${SHARED_DIR}/ansible-hosts" --list --yaml
    echo -e "\nRunning RHEL worker upgrade"
    sed -i 's|^remote_tmp.*|remote_tmp = /tmp/.ansible|g' /usr/share/ansible/openshift-ansible/ansible.cfg
    ansible-playbook -i "${SHARED_DIR}/ansible-hosts" /usr/share/ansible/openshift-ansible/playbooks/upgrade.yml -vvv || { export UPGRADE_FAILURE_TYPE="${testcase}"; return 1; }

    if [[ "${UPGRADE_RHEL_WORKER_BEFOREHAND}" == "triggered" ]]; then
        echo -e "RHEL worker upgrade completed, but the cluster upgrade hasn't been finished, check the cluster status again...\    n"
        check_upgrade_status
    fi

    echo "Check K8s version on the RHEL node"
    master_0=$(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{range .items[0]}{.metadata.name}{"\n"}{end}')
    rhel_0=$(oc get nodes -l node.openshift.io/os_id=rhel -o jsonpath='{range .items[0]}{.metadata.name}{"\n"}{end}')
    exp_version=$(oc get node ${master_0} --output=jsonpath='{.status.nodeInfo.kubeletVersion}' | cut -d '.' -f 1,2)
    act_version=$(oc get node ${rhel_0} --output=jsonpath='{.status.nodeInfo.kubeletVersion}' | cut -d '.' -f 1,2)

    echo -e "Expected K8s version is: ${exp_version}\nActual K8s version is: ${act_version}"
    if [[ ${exp_version} == "${act_version}" ]]; then
        echo "RHEL worker has correct K8s version"
    else
        echo "RHEL worker has incorrect K8s version"
        # Explicitly set failure to rhel for rhel worker upgrade failure
        export UPGRADE_FAILURE_TYPE="${testcase}"
        exit 1
    fi
    echo -e "oc get node -owide\n$(oc get node -owide)"
}

# Extract oc binary which is supposed to be identical with target release
# Default oc on OCP 4.16 not support OpenSSL 1.x
function extract_oc(){
    echo -e "Extracting oc\n"
    local retry=5 tmp_oc="/tmp/client-2" binary='oc'
    mkdir -p ${tmp_oc}
    if (( TARGET_MINOR_VERSION > 15 )) && (openssl version | grep -q "OpenSSL 1") ; then
        binary='oc.rhel8'
    fi
    while ! (env "NO_PROXY=*" "no_proxy=*" oc adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" --command=${binary} --to=${tmp_oc} ${TARGET});
    do
        echo >&2 "Failed to extract oc binary, retry..."
        (( retry -= 1 ))
        if (( retry < 0 )); then return 1; fi
        sleep 60
    done
    mv ${tmp_oc}/oc ${OC_DIR} -f
    export PATH="$PATH"
    which oc
    oc version --client
    return 0
}

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

function run_command_oc() {
    local try=0 max=40 ret_val

    if [[ "$#" -lt 1 ]]; then
        return 0
    fi

    while (( try < max )); do
        if ret_val=$(oc "$@" 2>&1); then
            break
        fi
        (( try += 1 ))
        sleep 3
    done

    if (( try == max )); then
        echo >&2 "Run:[oc $*]"
        echo >&2 "Get:[$ret_val]"
        return 255
    fi

    echo "${ret_val}"
}

function check_clusteroperators() {
    local tmp_ret=0 tmp_clusteroperator input column last_column_name tmp_clusteroperator_1 rc unavailable_operator degraded_operator skip_operator

    skip_operator="aro" # ARO operator versioned but based on RP git commit ID not cluster version
    echo "Make sure every operator do not report empty column"
    tmp_clusteroperator=$(mktemp /tmp/health_check-script.XXXXXX)
    input="${tmp_clusteroperator}"
    ${OC} get clusteroperator >"${tmp_clusteroperator}"
    column=$(head -n 1 "${tmp_clusteroperator}" | awk '{print NF}')
    last_column_name=$(head -n 1 "${tmp_clusteroperator}" | awk '{print $NF}')
    if [[ ${last_column_name} == "MESSAGE" ]]; then
        (( column -= 1 ))
        tmp_clusteroperator_1=$(mktemp /tmp/health_check-script.XXXXXX)
        awk -v end=${column} '{for(i=1;i<=end;i++) printf $i"\t"; print ""}' "${tmp_clusteroperator}" > "${tmp_clusteroperator_1}"
        input="${tmp_clusteroperator_1}"
    fi

    while IFS= read -r line
    do
        rc=$(echo "${line}" | awk '{print NF}')
        if (( rc != column )); then
            echo >&2 "The following line have empty column"
            echo >&2 "${line}"
            (( tmp_ret += 1 ))
        fi
    done < "${input}"
    rm -f "${tmp_clusteroperator}"

    echo "Make sure every operator reports correct version"
    if incorrect_version=$(${OC} get clusteroperator --no-headers | grep -v ${skip_operator} | awk -v var="${TARGET_VERSION}" '$2 != var') && [[ ${incorrect_version} != "" ]]; then
        echo >&2 "Incorrect CO Version: ${incorrect_version}"
        (( tmp_ret += 1 ))
    fi

    echo "Make sure every operator's AVAILABLE column is True"
    if unavailable_operator=$(${OC} get clusteroperator | awk '$3 == "False"' | grep "False"); then
        echo >&2 "Some operator's AVAILABLE is False"
        echo >&2 "$unavailable_operator"
        (( tmp_ret += 1 ))
    fi
    if ${OC} get clusteroperator -o jsonpath='{.items[].status.conditions[?(@.type=="Available")].status}'| grep -iv "True"; then
        echo >&2 "Some operators are unavailable, pls run 'oc get clusteroperator -o json' to check"
        (( tmp_ret += 1 ))
    fi

    echo "Make sure every operator's PROGRESSING column is False"
    if progressing_operator=$(${OC} get clusteroperator | awk '$4 == "True"' | grep "True"); then
        echo >&2 "Some operator's PROGRESSING is True"
        echo >&2 "$progressing_operator"
        (( tmp_ret += 1 ))
    fi
    if ${OC} get clusteroperator -o json | jq '.items[].status.conditions[] | select(.type == "Progressing") | .status' | grep -iv "False"; then
        echo >&2 "Some operators are Progressing, pls run 'oc get clusteroperator -o json' to check"
        (( tmp_ret += 1 ))
    fi

    echo "Make sure every operator's DEGRADED column is False"
    # In disconnected install, openshift-sample often get into Degrade state, so it is better to remove them from cluster from flexy post-action
    #degraded_operator=$(${OC} get clusteroperator | grep -v "openshift-sample" | awk '$5 == "True"')
    if degraded_operator=$(${OC} get clusteroperator | awk '$5 == "True"' | grep "True"); then
        echo >&2 "Some operator's DEGRADED is True"
        echo >&2 "$degraded_operator"
        (( tmp_ret += 1 ))
    fi
    #co_check=$(${OC} get clusteroperator -o json | jq '.items[] | select(.metadata.name != "openshift-samples") | .status.conditions[] | select(.type == "Degraded") | .status'  | grep -iv 'False')
    if ${OC} get clusteroperator -o jsonpath='{.items[].status.conditions[?(@.type=="Degraded")].status}'| grep -iv 'False'; then
        echo >&2 "Some operators are Degraded, pls run 'oc get clusteroperator -o json' to check"
        (( tmp_ret += 1 ))
    fi

    return $tmp_ret
}

function wait_clusteroperators_continous_success() {
    local try=0 continous_successful_check=0 passed_criteria=3 max_retries=30
    while (( try < max_retries && continous_successful_check < passed_criteria )); do
        echo "Checking #${try}"
        if check_clusteroperators; then
            echo "Passed #${continous_successful_check}"
            (( continous_successful_check += 1 ))
        else
            echo "cluster operators are not ready yet, wait and retry..."
            continous_successful_check=0
        fi
        sleep 60
        (( try += 1 ))
    done
    if (( continous_successful_check != passed_criteria )); then
        echo >&2 "Some cluster operator does not get ready or not stable"
        echo "Debug: current CO output is:"
        oc get co
        check_failed_operator
        return 1
    else
        echo "All cluster operators status check PASSED"
        return 0
    fi
}

function check_mcp() {
    local updating_mcp unhealthy_mcp tmp_output

    tmp_output=$(mktemp)
    oc get machineconfigpools -o custom-columns=NAME:metadata.name,CONFIG:spec.configuration.name,UPDATING:status.conditions[?\(@.type==\"Updating\"\)].status --no-headers > "${tmp_output}" || true
    # using the size of output to determinate if oc command is executed successfully
    if [[ -s "${tmp_output}" ]]; then
        updating_mcp=$(cat "${tmp_output}" | grep -v "False")
        if [[ -n "${updating_mcp}" ]]; then
            echo "Some mcp is updating..."
            echo "${updating_mcp}"
            return 1
        fi
    else
        echo "Did not run 'oc get machineconfigpools' successfully!"
        return 1
    fi

    # Do not check UPDATED on purpose, beause some paused mcp would not update itself until unpaused
    oc get machineconfigpools -o custom-columns=NAME:metadata.name,CONFIG:spec.configuration.name,UPDATING:status.conditions[?\(@.type==\"Updating\"\)].status,DEGRADED:status.conditions[?\(@.type==\"Degraded\"\)].status,DEGRADEDMACHINECOUNT:status.degradedMachineCount --no-headers > "${tmp_output}" || true
    # using the size of output to determinate if oc command is executed successfully
    if [[ -s "${tmp_output}" ]]; then
        unhealthy_mcp=$(cat "${tmp_output}" | grep -v "False.*False.*0")
        if [[ -n "${unhealthy_mcp}" ]]; then
            echo "Detected unhealthy mcp:"
            echo "${unhealthy_mcp}"
            echo "Real-time detected unhealthy mcp:"
            oc get machineconfigpools -o custom-columns=NAME:metadata.name,CONFIG:spec.configuration.name,UPDATING:status.conditions[?\(@.type==\"Updating\"\)].status,DEGRADED:status.conditions[?\(@.type==\"Degraded\"\)].status,DEGRADEDMACHINECOUNT:status.degradedMachineCount | grep -v "False.*False.*0"
            echo "Real-time full mcp output:"
            oc get machineconfigpools
            echo ""
            unhealthy_mcp_names=$(echo "${unhealthy_mcp}" | awk '{print $1}')
            echo "Using oc describe to check status of unhealthy mcp ..."
            for mcp_name in ${unhealthy_mcp_names}; do
              echo "Name: $mcp_name"
              oc describe mcp $mcp_name || echo "oc describe mcp $mcp_name failed"
            done
            return 2
        fi
    else
        echo "Did not run 'oc get machineconfigpools' successfully!"
        return 1
    fi
    return 0
}

function wait_mcp_continous_success() {
    local try=0 continous_successful_check=0 passed_criteria max_retries ret=0 interval=30
    num=$(oc get node --no-headers | wc -l)
    max_retries=$(expr $num \* 20 \* 60 \/ $interval) # Wait 20 minutes for each node, try 60/interval times per minutes
    passed_criteria=$(expr 5 \* 60 \/ $interval) # We consider mcp to be updated if its status is updated for 5 minutes
    local continous_degraded_check=0 degraded_criteria=5
    while (( try < max_retries && continous_successful_check < passed_criteria )); do
        echo "Checking #${try}"
        ret=0
        check_mcp || ret=$?
        if [[ "$ret" == "0" ]]; then
            continous_degraded_check=0
            echo "Passed #${continous_successful_check}"
            (( continous_successful_check += 1 ))
        elif [[ "$ret" == "1" ]]; then
            echo "Some machines are updating..."
            continous_successful_check=0
            continous_degraded_check=0
        else
            continous_successful_check=0
            echo "Some machines are degraded #${continous_degraded_check}..."
            (( continous_degraded_check += 1 ))
            if (( continous_degraded_check >= degraded_criteria )); then
                break
            fi
        fi
        echo "wait and retry..."
        sleep ${interval}
        (( try += 1 ))
    done
    if (( continous_successful_check != passed_criteria )); then
        echo >&2 "Some mcp does not get ready or not stable"
        echo "Debug: current mcp output is:"
        oc get machineconfigpools
        # Explicitly set failure to mco
        export UPGRADE_FAILURE_TYPE="machine-config"
        return 1
    else
        echo "All mcp status check PASSED"
        return 0
    fi
}

function wait_node_continous_success() {
    local try=0 continous_successful_check=0 passed_criteria=20 max_retries=80 interval=30
    while (( try < max_retries && continous_successful_check < passed_criteria )); do
        sleep ${interval}
        if check_node; then
            (( continous_successful_check += 1 ))
        else
            continous_successful_check=0
        fi
        echo "${try} wait and retry..."
        echo "Continue success time: ${continous_successful_check}"
        (( try += 1 ))
    done
    if (( continous_successful_check != passed_criteria )); then
        echo >&2 "Some nodes does not get ready or not stable"
        echo "Debug: current node output is:"
        oc get node
        # Explicitly set failure to node
        export UPGRADE_FAILURE_TYPE="node"
        return 1
    else
        echo "All node status check PASSED"
        return 0
    fi
}

function check_node() {
    local node_number ready_number testcase="node"
    node_number=$(${OC} get node |grep -vc STATUS)
    ready_number=$(${OC} get node |grep -v STATUS | awk '$2 == "Ready"' | wc -l)
    export IMPLICIT_ENABLED_CASES="${IMPLICIT_ENABLED_CASES} ${testcase}"
    if (( node_number == ready_number )); then
        echo "All nodes status check PASSED"
        return 0
    else
        if (( ready_number == 0 )); then
            echo >&2 "No any ready node"
        else
            echo >&2 "We found failed node"
            oc get node |grep -v STATUS | awk '$2 != "Ready"'
        fi
        # Explicitly set failure to node
        export UPGRADE_FAILURE_TYPE="${testcase}"
        return 1
    fi
}

function check_pod() {
    echo "Show all pods status for reference/debug"
    oc get pods --all-namespaces
}

function health_check() {
    echo "Step #1: Make sure no degrated or updating mcp"
    wait_mcp_continous_success

    echo "Step #2: check all cluster operators get stable and ready"
    wait_clusteroperators_continous_success

    echo "Step #3: Make sure every machine is in 'Ready' status"
    check_node

    echo "Step #4: check all pods are in status running or complete"
    check_pod
}

# Check if a build is signed
function check_signed() {
    local digest algorithm hash_value response try max_retries payload="${1}"
    if [[ "${payload}" =~ "@sha256:" ]]; then
        digest="$(echo "${payload}" | cut -f2 -d@)"
        echo "The target image is using digest pullspec, its digest is ${digest}"
    else
        digest="$(oc image info "${payload}" -o json | jq -r ".digest")"
        echo "The target image is using tagname pullspec, its digest is ${digest}"
    fi
    algorithm="$(echo "${digest}" | cut -f1 -d:)"
    hash_value="$(echo "${digest}" | cut -f2 -d:)"
    try=0
    max_retries=3
    response=0
    while (( try < max_retries && response != 200 )); do
        echo "Trying #${try}"
        response=$(https_proxy="" HTTPS_PROXY="" curl -L --silent --output /dev/null --write-out %"{http_code}" "https://mirror.openshift.com/pub/openshift-v4/signatures/openshift/release/${algorithm}=${hash_value}/signature-1")
        (( try += 1 ))
        sleep 60
    done
    if (( response == 200 )); then
        echo "${payload} is signed" && return 0
    else
        echo "Seem like ${payload} is not signed" && return 1
    fi
}

# Check if admin ack is required before upgrade
function admin_ack() {
    local source_version="${1}" target_version="${2}" source_minor_version target_minor_version
    source_minor_version="$(echo "$source_version" | cut -f2 -d.)"
    target_minor_version="$(echo "$target_version" | cut -f2 -d.)"

    if (( source_minor_version == target_minor_version )) || (( source_minor_version < 8 )); then
        echo "Admin ack is not required in either z-stream upgrade or 4.7 and earlier" && return
    fi

    local out; out="$(oc -n openshift-config-managed get configmap admin-gates -o json | jq -r ".data")"
    echo -e "All admin acks:\n${out}"
    if [[ ${out} != *"ack-4.${source_minor_version}"* ]]; then
        echo "Admin ack not required: ${out}" && return
    fi

    echo -e "Require admin ack:\n ${out}"
    local wait_time_loop_var=0 ack_data testcase="OCP-44827"
    export IMPLICIT_ENABLED_CASES="${IMPLICIT_ENABLED_CASES} ${testcase}"

    ack_data="$(echo "${out}" | jq -r "keys[]")"
    for ack in ${ack_data};
    do
        # e.g.: ack-4.12-kube-1.26-api-removals-in-4.13
        if [[ "${ack}" == *"ack-4.${source_minor_version}"* ]]
        then
            echo "Admin ack patch data is: ${ack}"
            oc -n openshift-config patch configmap admin-acks --patch '{"data":{"'"${ack}"'": "true"}}' --type=merge
        fi
    done
    echo "Admin-acks patch gets started"

    echo -e "sleep 5 mins wait admin-acks patch to be valid...\n"
    while (( wait_time_loop_var < 5 )); do
        sleep 1m
        echo -e "wait_time_passed=${wait_time_loop_var} min.\n"
        if ! oc adm upgrade | grep "AdminAckRequired"; then
            echo -e "Admin-acks patch PASSED\n"
            return 0
        else
            echo -e "Admin-acks patch still in processing, waiting...\n"
        fi
        (( wait_time_loop_var += 1 ))
    done
    if (( wait_time_loop_var >= 5 )); then
        echo >&2 "Timed out waiting for admin-acks completing, exiting"
        # Explicitly set failure to admin_ack
        export UPGRADE_FAILURE_TYPE="${testcase}"
        return 1
    fi
}

# Upgrade the cluster to target release
function upgrade() {
    set_channel $TARGET_VERSION
    local retry=5 unrecommended_conditional_updates
    while (( retry > 0 )); do
        unrecommended_conditional_updates=$(oc get clusterversion version -o json | jq -r '.status.conditionalUpdates[]? | select((.conditions[].type == "Recommended") and (.conditions[].status != "True")) | .release.version' | xargs)
        echo "Not recommended conditions: "
        echo "${unrecommended_conditional_updates}"
        if [[ -z "${unrecommended_conditional_updates}" ]]; then
            retry=$((retry - 1))
            sleep 60
            echo "No conditionalUpdates update available! Retry..."
        else
            #shellcheck disable=SC2076
            if [[ " $unrecommended_conditional_updates " =~ " $TARGET_VERSION " ]]; then
                echo "Error: $TARGET_VERSION is not recommended, for details please refer:"
                oc get clusterversion version -o json | jq -r '.status.conditionalUpdates[]? | select((.conditions[].type == "Recommended") and (.conditions[].status != "True"))'
                exit 1
            fi
            break
        fi
    done

    run_command "oc adm upgrade --to-image=${TARGET} --allow-explicit-upgrade --force=${FORCE_UPDATE}"
    echo "Upgrading cluster to ${TARGET} gets started..."
}

# Monitor the upgrade status
function check_upgrade_status() {
    local wait_upgrade="${TIMEOUT}" interval=1 out avail progress stat_cmd stat='empty' oldstat='empty' filter='[0-9]+h|[0-9]+m|[0-9]+s|[0-9]+%|[0-9]+.[0-9]+s|[0-9]+ of|\s+|\n' start_time end_time
    echo -e "Upgrade checking start at $(date "+%F %T")\n"
    start_time=$(date "+%s")
    # print once to log (including full messages)
    oc adm upgrade || true
    # log oc adm upgrade (excluding garbage messages)
    stat_cmd="oc adm upgrade | grep -vE 'Upstream is unset|Upstream: https|available channels|No updates available|^$'"
    # if available (version 4.16+) log "upgrade status" instead
    if [[ -n "${TARGET_MINOR_VERSION}" ]] && [[ "${TARGET_MINOR_VERSION}" -ge "16" ]] ; then
        stat_cmd="env OC_ENABLE_CMD_UPGRADE_STATUS=true oc adm upgrade status 2>&1 | grep -vE 'no token is currently in use|for additional description and links'"
    fi
    while (( wait_upgrade > 0 )); do
        sleep ${interval}m
        wait_upgrade=$(( wait_upgrade - interval ))
        # if output is different from previous (ignoring irrelevant time/percentage difference), write to log
        if stat="$(eval "${stat_cmd}")" && [ -n "$stat" ] && ! diff -qw <(sed -zE "s/${filter}//g" <<< "${stat}") <(sed -zE "s/${filter}//g" <<< "${oldstat}") >/dev/null ; then
            echo -e "=== Upgrade Status $(date "+%T") ===\n${stat}\n\n\n\n"
            oldstat=${stat}
        fi
        if ! out="$(oc get clusterversion --no-headers || false)"; then
            echo "Error occurred when getting clusterversion"
            continue
        fi
        avail="$(echo "${out}" | awk '{print $3}')"
        progress="$(echo "${out}" | awk '{print $4}')"
        if [[ ${avail} == "True" && ${progress} == "False" && ${out} == *"Cluster version is ${TARGET_VERSION}" ]]; then
            echo -e "Upgrade checking end at $(date "+%F %T") - succeed\n"
            end_time=$(date "+%s")
            echo -e "Eclipsed Time: $(( ($end_time - $start_time) / 60 ))m\n"
            return 0
        fi
        if [[ "${UPGRADE_RHEL_WORKER_BEFOREHAND}" == "true" && ${avail} == "True" && ${progress} == "True" && ${out} == *"Unable to apply ${TARGET_VERSION}"* ]]; then
            UPGRADE_RHEL_WORKER_BEFOREHAND="triggered"
            echo -e "Upgrade stuck at updating RHEL worker, run the RHEL worker upgrade now...\n\n"
            return 0
        fi
    done
    if [[ ${wait_upgrade} -le 0 ]]; then
        echo -e "Upgrade checking timeout at $(date "+%F %T")\n"
        end_time=$(date "+%s")
        echo -e "Eclipsed Time: $(( ($end_time - $start_time) / 60 ))m\n"
        check_failed_operator
        return 1
    fi
}

# Check version, state in history
function check_history() {
    local version state testcase="OCP-21588"
    version=$(oc get clusterversion/version -o jsonpath='{.status.history[0].version}')
    state=$(oc get clusterversion/version -o jsonpath='{.status.history[0].state}')
    export IMPLICIT_ENABLED_CASES="${IMPLICIT_ENABLED_CASES} ${testcase}"
    if [[ ${version} == "${TARGET_VERSION}" && ${state} == "Completed" ]]; then
        echo "History check PASSED, cluster is now upgraded to ${TARGET_VERSION}" && return 0
    else
        echo >&2 "History check FAILED, cluster upgrade to ${TARGET_VERSION} failed, current version is ${version}, exiting"
	# Explicitly set failure to cvo
        export UPGRADE_FAILURE_TYPE="${testcase}"
	return 1
    fi
}

function echo_e2e_tags() {
    echo "In function: ${FUNCNAME[1]}"
    echo "E2E_RUN_TAGS: '${E2E_RUN_TAGS}'"
}

function filter_test_by_platform() {
    local platform ipixupi
    ipixupi='upi'
    if (oc get configmap openshift-install -n openshift-config &>/dev/null) ; then
        ipixupi='ipi'
    fi
    platform="$(oc get infrastructure cluster -o yaml | yq '.status.platform' | tr 'A-Z' 'a-z')"
    extrainfoCmd="oc get infrastructure cluster -o yaml | yq '.status'"
    if [[ -n "$platform" ]] ; then
        case "$platform" in
            external|kubevirt|none|powervs)
                export E2E_RUN_TAGS="@baremetal-upi and ${E2E_RUN_TAGS}"
                eval "$extrainfoCmd"
                ;;
            alibabacloud)
                export E2E_RUN_TAGS="@alicloud-${ipixupi} and ${E2E_RUN_TAGS}"
                ;;
            aws|azure|baremetal|gcp|ibmcloud|nutanix|openstack|vsphere)
                export E2E_RUN_TAGS="@${platform}-${ipixupi} and ${E2E_RUN_TAGS}"
                ;;
            *)
                echo "Unexpected, got platform as '$platform'"
                eval "$extrainfoCmd"
                ;;
        esac
    fi
    echo_e2e_tags
}

function filter_test_by_proxy() {
    local proxy
    proxy="$(oc get proxies.config.openshift.io cluster -o yaml | yq '.spec|(.httpProxy,.httpsProxy)' | uniq)"
    if [[ -n "$proxy" ]] && [[ "$proxy" != 'null' ]] ; then
        export E2E_RUN_TAGS="@proxy and ${E2E_RUN_TAGS}"
    fi
    echo_e2e_tags 
}

function filter_test_by_fips() {
    local data
    data="$(oc get configmap cluster-config-v1 -n kube-system -o yaml | yq '.data')"
    if ! (grep --ignore-case --quiet 'fips' <<< "$data") ; then
        export E2E_RUN_TAGS="not @fips and ${E2E_RUN_TAGS}"
    fi
    echo_e2e_tags
}

function filter_test_by_sno() {
    local nodeno
    nodeno="$(oc get nodes --no-headers | wc -l)"
    if [[ $nodeno -eq 1 ]] ; then
        export E2E_RUN_TAGS="@singlenode and ${E2E_RUN_TAGS}"
    fi
    echo_e2e_tags 
}

function filter_test_by_network() {
    local networktype
    networktype="$(oc get network.config/cluster -o yaml | yq '.spec.networkType')"
    case "${networktype,,}" in
        openshiftsdn)
            networktag='@network-openshiftsdn'
            ;;
        ovnkubernetes)
            networktag='@network-ovnkubernetes'
            ;;
        other)
            networktag=''
            ;;
        *)
            echo "######Expected network to be SDN/OVN/Other, but got: $networktype"
            ;;
    esac
    if [[ -n $networktag ]] ; then
        export E2E_RUN_TAGS="${networktag} and ${E2E_RUN_TAGS}"
    fi
    echo_e2e_tags
}

function filter_test_by_version() { 
    local xversion yversion
    IFS='.' read xversion yversion _ < <(oc version -o yaml | yq '.openshiftVersion')
    if [[ -n $xversion ]] && [[ $xversion -eq 4 ]] && [[ -n $yversion ]] && [[ $yversion =~ [12][0-9] ]] ; then
        export E2E_RUN_TAGS="@${xversion}.${yversion} and ${E2E_RUN_TAGS}"
    fi
    echo_e2e_tags
}

function filter_test_by_arch() {
    local node_archs arch_tags
    mapfile -t node_archs < <(oc get nodes -o yaml | yq '.items[].status.nodeInfo.architecture' | sort -u | sed 's/^/@/g')
    arch_tags="${node_archs[*]/%/ and}"
    case "${#node_archs[@]}" in
        0)
            echo "=========================="
            echo "Error: got unexpected arch"
            oc get nodes -o yaml
            echo "=========================="
            ;;
        1)
            export E2E_RUN_TAGS="${arch_tags[*]} ${E2E_RUN_TAGS}"
            ;;
        *)
            export E2E_RUN_TAGS="@heterogeneous and ${arch_tags[*]} ${E2E_RUN_TAGS}"
            ;;
    esac
    echo_e2e_tags
}

function filter_tests() {
    filter_test_by_fips
    filter_test_by_proxy
    filter_test_by_sno
    filter_test_by_network
    filter_test_by_platform
    filter_test_by_arch
    filter_test_by_version

    echo_e2e_tags
}

function summarize_test_results() {
    # summarize test results
    echo "Summarizing test results..."
    if ! [[ -d "${ARTIFACT_DIR:-'/default-non-exist-dir'}" ]] ; then
        echo "Artifact dir '${ARTIFACT_DIR}' not exist"
        exit 0
    else
        echo "Artifact dir '${ARTIFACT_DIR}' exist"
        ls -lR "${ARTIFACT_DIR}"
        files="$(find "${ARTIFACT_DIR}" -name '*.xml' | wc -l)"
        if [[ "$files" -eq 0 ]] ; then
            echo "There are no JUnit files"
            exit 0
        fi
    fi
    declare -A results=([failures]='0' [errors]='0' [skipped]='0' [tests]='0')
    grep -r -E -h -o 'testsuite.*tests="[0-9]+"[^>]*' "${ARTIFACT_DIR}" > /tmp/zzz-tmp.log || exit 0
    while read row ; do
	for ctype in "${!results[@]}" ; do
            count="$(sed -E "s/.*$ctype=\"([0-9]+)\".*/\1/" <<< $row)"
            if [[ -n $count ]] ; then
                let results[$ctype]+=count || true
            fi
        done
    done < /tmp/zzz-tmp.log

    TEST_RESULT_FILE="${ARTIFACT_DIR}/test-results.yaml"
    cat > "${TEST_RESULT_FILE}" <<- EOF
cucushift-chainupgrade-toimage:
  total: ${results[tests]}
  failures: ${results[failures]}
  errors: ${results[errors]}
  skipped: ${results[skipped]}
EOF

    if [ ${results[failures]} != 0 ] ; then
        echo '  failingScenarios:' >> "${TEST_RESULT_FILE}"
        readarray -t failingscenarios < <(grep -h -r -E 'cucumber.*features/.*.feature' "${ARTIFACT_DIR}/.." | cut -d':' -f3- | sed -E 's/^( +)//;s/\x1b\[[0-9;]*m$//' | sort)
        for (( i=0; i<${results[failures]}; i++ )) ; do
            echo "    - ${failingscenarios[$i]}" >> "${TEST_RESULT_FILE}"
        done
    fi
    cat "${TEST_RESULT_FILE}" | tee -a "${SHARED_DIR}/openshift-upgrade-qe-test-report" || true
}

function run_upgrade_e2e() {
    local idx="$1"
    export PARALLEL=4
    local E2E_SKIP_TAGS="not @console
          and not @destructive
          and not @disconnected
          and not @flaky
          and not @inactive
          and not @prod-only
          and not @stage-only
          and not @upgrade-check
          and not @upgrade-prepare
          and not @serial
    "
    local e2e_start_time e2e_end_time

    e2e_start_time=$(date +%s)
    echo "Starting the upgrade e2e tests on $(date "+%F %T")"
    E2E_RUN_TAGS="$E2E_RUN_TAGS and $E2E_SKIP_TAGS"

    filter_tests

    cp -Lrvf "${KUBECONFIG}" /tmp/kubeconfig

    #shellcheck source=${SHARED_DIR}/runtime_env
    source "${SHARED_DIR}/runtime_env"

    pushd /verification-tests
    # run normal tests
    export BUSHSLICER_REPORT_DIR="${ARTIFACT_DIR}/parallel-normal-${idx}"
    parallel_cucumber -n "${PARALLEL}" --first-is-1 --type cucumber --serialize-stdout --combine-stderr --prefix-output-with-test-env-number --exec \
    'export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS=$(echo ${USERS} | cut -d "," -f ${TEST_ENV_NUMBER},$((${TEST_ENV_NUMBER}+${PARALLEL})),$((${TEST_ENV_NUMBER}+${PARALLEL}*2)));
     export WORKSPACE=/tmp/dir${TEST_ENV_NUMBER};
     parallel_cucumber --group-by found --only-group ${TEST_ENV_NUMBER} -o "--tags \"${E2E_RUN_TAGS} and not @admin\" -p junit"' || true

    # run admin tests
    export BUSHSLICER_REPORT_DIR="${ARTIFACT_DIR}/parallel-admin-${idx}"
    parallel_cucumber -n "${PARALLEL}" --first-is-1 --type cucumber --serialize-stdout --combine-stderr --prefix-output-with-test-env-number --exec \
    'export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS=$(echo ${USERS} | cut -d "," -f ${TEST_ENV_NUMBER},$((${TEST_ENV_NUMBER}+${PARALLEL})),$((${TEST_ENV_NUMBER}+${PARALLEL}*2)));
     export WORKSPACE=/tmp/dir${TEST_ENV_NUMBER};
     parallel_cucumber --group-by found --only-group ${TEST_ENV_NUMBER} -o "--tags \"${E2E_RUN_TAGS} and @admin\" -p junit"' || true

    summarize_test_results
    popd
    echo "Ending the upgrade e2e tests on $(date "+%F %T")"
    e2e_end_time=$(date +%s)
    echo "e2e test take $(( ($e2e_end_time - $e2e_start_time)/60 )) minutes"
}

function set_channel(){
    local x_ver y_ver version="$1"
    x_ver=$( echo "${version}" | cut -f1 -d. )
    y_ver=$( echo "${version}" | cut -f2 -d. )
    ver="${x_ver}.${y_ver}"
    target_channel="${UPGRADE_CHANNEL}-${ver}"
    if ! oc adm upgrade channel ${target_channel}; then
        echo "Fail to change channel to ${target_channel}!"
        exit 1
    fi
}

if [[ -f "${SHARED_DIR}/kubeconfig" ]] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

# Setup proxy if it's present in the shared dir
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

export TARGET_MINOR_VERSION=""

# upgrade-edge file expects a comma separated releases list like target_release1,target_release2,...
release_string="$(< "${SHARED_DIR}/upgrade-edge")"
# shellcheck disable=SC2207
TARGET_RELEASES=($(echo "$release_string" | tr ',' ' '))
echo "Upgrade targets are ${TARGET_RELEASES[*]}"

export OC="run_command_oc"
# Set genenral upgrade ci failure to overall as default
export UPGRADE_FAILURE_TYPE="overall"

# The cases are from existing general checkpoints enabled implicitly in upgrade step, which may be a possible UPGRADE_FAILURE_TYPE
export IMPLICIT_ENABLED_CASES=""

# Target version oc will be extract in the /tmp/client directory, use it first
mkdir -p /tmp/client
export OC_DIR="/tmp/client"
export PATH=${OC_DIR}:$PATH
index=0
for target in "${TARGET_RELEASES[@]}"; do
    run_command "oc get machineconfigpools"
    run_command "oc get machineconfig"

    (( index += 1 ))
    export TARGET="${target}"
    TARGET_VERSION="$(env "NO_PROXY=*" "no_proxy=*" oc adm release info "${TARGET}" --output=json | jq -r '.metadata.version')"
    TARGET_MINOR_VERSION="$(echo "${TARGET_VERSION}" | cut -f2 -d.)"
    export TARGET_VERSION
    extract_oc

    SOURCE_VERSION="$(oc get clusterversion --no-headers | awk '{print $2}')"
    SOURCE_MINOR_VERSION="$(echo "${SOURCE_VERSION}" | cut -f2 -d.)"
    export SOURCE_VERSION
    export SOURCE_MINOR_VERSION
    echo -e "Source release version is: ${SOURCE_VERSION}\nSource minor version is: ${SOURCE_MINOR_VERSION}"

    echo -e "Target release version is: ${TARGET_VERSION}\nTarget minor version is: ${TARGET_MINOR_VERSION}"

    export FORCE_UPDATE="false"
    if ! check_signed "${TARGET}"; then
        echo "You're updating to an unsigned images, you must override the verification using --force flag"
        FORCE_UPDATE="true"
    else
        echo "You're updating to a signed images, so run the upgrade command without --force flag"
    fi
    if [[ "${FORCE_UPDATE}" == "false" ]]; then
        admin_ack "${SOURCE_VERSION}" "${TARGET_VERSION}"
        cco_annotation "${SOURCE_VERSION}" "${TARGET_VERSION}"
    fi
    if [[ "${UPGRADE_CCO_MANUAL_MODE}" == "oidc" ]]; then
	    update_cloud_credentials_oidc
    fi
    if [[ "${DISABLE_BOOT_IMAGE_UPDATE}" == "true" ]]; then
	#Disable updated boot images feature for jobs with custom boot image specified in certain upgrade paths
        echo "Checking conditions for disabling boot image updates..."

        # Get platform
        PLATFORM=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}')

        # Check all conditions
        if [[ "${TARGET_MINOR_VERSION}" == "19" ]] && [[ "${PLATFORM}" =~ ^(AWS|GCP)$ ]]; then
            disable_boot_image_update
        else
            echo "Skipping boot image update disablement."
        fi
    fi
    upgrade
    check_upgrade_status

    if [[ "${TARGET_MINOR_VERSION}" -lt "19" ]] && [[ $(oc get nodes -l node.openshift.io/os_id=rhel) != "" ]]; then
        echo "Found rhel worker..."
        run_command "oc get node -owide"
        if [[ $(oc get machineconfigpools worker -ojson | jq -r '.spec.paused') == "true" ]]; then
            echo "worker mcp are paused, it sounds eus upgrade, skip rhel worker upgrade here, should upgrade them after worker mcp unpaused"
	    #Temporary workaround for 4.14 to 4.16 cpou test with RHEL workers, would be removed until https://github.com/openshift/openshift-ansible/pull/12531 merged
	    if [[ "${SOURCE_MINOR_VERSION}" == "14" ]]; then
	        echo "Running workaround for https://issues.redhat.com/browse/OCPBUGS-32057 in 4.14 to 4.16 cpou test"
		rhel_repo
	        rhel_pre_unpause
	    fi
        else
            rhel_repo
            rhel_upgrade
        fi
    fi
    check_history
    health_check
    currentPlugin=$(oc get network.config.openshift.io cluster -o jsonpath='{.status.networkType}')
    if [[ ${TARGET_MINOR_VERSION} == "16" && ${currentPlugin} == "OpenShiftSDN" ]]; then
	echo "The cluster is running version 4.16 with OpenShift SDN, and it needs to be migrated to OVN before upgrading"
	sdn2ovn
	health_check
    fi

    run_command "oc get -o json nodes.config.openshift.io cluster | jq -r .spec.cgroupMode"
    # From OCP 4.19, we do not support cgroupmode v1
    # So update the 'cgroupMode' in the 'cluster' object of nodes.config.openshift.io resource type to 'v2'
    if [[ "${TARGET_MINOR_VERSION}" -eq "18" ]] && [[ "$(oc get -o json nodes.config.openshift.io cluster | jq -r .spec.cgroupMode)" == "v1" ]]; then
        run_command "oc patch --type=merge --patch='{\"spec\":{\"cgroupMode\":\"v2\"}}' nodes.config.openshift.io cluster"
        echo "New cgroupMode:"
        run_command "oc get -o json nodes.config.openshift.io cluster | jq -r .spec"
        wait_node_continous_success
        wait_mcp_continous_success
    fi

    if [[ -n "${E2E_RUN_TAGS}" ]]; then
	echo "Start e2e test..."
	test_log_dir="${ARTIFACT_DIR}/test-logs"
        mkdir -p ${test_log_dir}
        run_upgrade_e2e "${index}" &>> "${test_log_dir}/4.${TARGET_MINOR_VERSION}-e2e-log.txt" || true
	echo "End e2e test..."
    fi
done
