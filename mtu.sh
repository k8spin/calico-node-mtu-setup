#!/bin/bash

CNI_NET_DIR="${1}"
CALICO_CONFIG_FILE_PATH="${CNI_NET_DIR}/${CNI_CONF_NAME}"

NEW_CALICO_TEMP_FILE_PATH="/tmp/${CNI_CONF_NAME}"

restart_node_pods(){
    kubectl get pods -A -o json > /tmp/pods.json
    cat /tmp/pods.json | jq -c  '.items[] | select(.spec.nodeName=="'"${NODE_NAME}"'")' > /tmp/node-pods.json
    cat /tmp/node-pods.json | jq -r '.metadata | "kubectl -n \(.namespace) delete pod \(.name)"' > /tmp/delete-node-pods-commands
    while IFS= read line
    do
        if grep -q "calico-node-" <<< "$line"; then 
            # Includes calico-node- and calico-node-mtu-setup-
            echo "$(date) Calico Pod must not be restarted"
        else
            bash <(echo "$line")
        fi
    done <"/tmp/delete-node-pods-commands"
}


while [ true ]
do
    if ! grep -q ${MTU_SIZE} ${CALICO_CONFIG_FILE_PATH}
    then
        echo "$(date) MTU Configuration not found"
        cni_plugins_lenght=$(cat ${CALICO_CONFIG_FILE_PATH} | jq '.plugins | length')
        for i in `seq 0 "$((${cni_plugins_lenght}-1))"`;
        do
            plugin_type="$(cat ${CALICO_CONFIG_FILE_PATH} | jq -r .plugins[${i}].type)"
            if [ ${plugin_type} == "calico" ]
            then
                echo "$(date) Applying MTU Configuration"
                cat ${CALICO_CONFIG_FILE_PATH} | jq -r '. | .plugins['"${i}"'].mtu = '"${MTU_SIZE}"'' > ${NEW_CALICO_TEMP_FILE_PATH}
                cat ${NEW_CALICO_TEMP_FILE_PATH} > ${CALICO_CONFIG_FILE_PATH}
                echo "$(date) Restarting node Pods"
                restart_node_pods
                echo "$(date) Restarted"
            fi
        done
    fi
    sleep ${RETRY_PERIOD}
done
