#!/bin/sh
set -e;
set -o errexit;
set -o nounset;
# set -o xtrace

export DEBIAN_FRONTEND=noninteractive;

# wait debconf to be available
waitDebconf() {
    while ( set -x; sudo lsof -f -- /var/cache/debconf/config.dat ) ; do
        echo "Waiting for debconf to be available";
        sleep 5;
    done
}

# wait dpkg to be available
waitDpkg() {
    while ( set -x; sudo lsof -f -- /var/lib/dpkg/lock ) ; do
        echo "Waiting for dpkg to be available";
        sleep 5;
    done
}

usage() { echo "Usage: $0 -e <string> -id <string> -cmd <string>" 1>&2; exit 1; }

command_exists() { command -v "$@" > /dev/null 2>&1; }

################################ ARGUMENTS ################################

while getopts ":h::s::r::c:" OPT; do
    case ${OPT} in
        h)
            usage;
            exit 0;
            ;;
        s)
            SCALE_SET_NAME="$OPTARG";
            ;;
        r)
            RESOURCE_GROUP_ID="$OPTARG";
            ;;
        c)
            RANCHER_COMMAND="$OPTARG";
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2;
            usage;
            exit 1;
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2;
            usage;
            exit 1;
            ;;
    esac
done

if [ -z "${SCALE_SET_NAME+x}" ]; then
    echo You need to provide an Scaleset name;
    usage;
    exit 1;
fi

if [ -z "${RESOURCE_GROUP_ID+x}" ]; then
    echo You need to provide a resource group id;
    usage;
    exit 1;
fi

if [ -z "${RANCHER_COMMAND+x}" ]; then
    echo You need to provide a rancher command;
    usage;
    exit 1;
fi

################################ PRE-START ################################

waitDebconf;
echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections;

waitDpkg;
( set -x; sudo apt-get update; )

waitDpkg;
( set -x; sudo apt-mark hold walinuxagent; )

waitDpkg;
( set -x; sudo apt-get upgrade -y -q; )

waitDpkg;
( set -x; sudo apt-get install -y -q curl htop jq; )

waitDpkg;
( set -x; sudo apt-mark unhold walinuxagent; )


if ! command_exists docker || [ ! -e /var/run/docker.sock ]; then
    waitDpkg;
    ( set -x; curl https://releases.rancher.com/install-docker/1.12.sh | sh; )
    waitDpkg;
    ( set -x; apt-mark hold docker-engine; )
    mkdir -p /mnt/docker;
    echo "{\n  \"graph\": \"/mnt/docker\"\n}" > /etc/docker/daemon.json; # move all docker data (image, volumes) to virtual disk
    ( set -x; service docker restart; )
fi

################################ START ################################

metadata() {
    API_ENDPOINT="http://169.254.169.254/metadata"
    API_VERSION="2017-03-01"
    URL_PATH="$1" # instance/compute
    KEY="$2"  # .vmId
    ( set -x; echo `curl -s -H "Metadata:true" -L -G -d "api-version=${API_VERSION}" ${API_ENDPOINT}/${URL_PATH} | jq ${KEY} -r`)
}

VM_UUID=$(metadata "instance/compute" ".vmId")
VM_NAME=$(metadata "instance/compute" ".name")
VM_IP=$(metadata "instance/network/interface/0/ipv4/ipaddress/0" ".ipaddress")

VM_ID=${RESOURCE_GROUP_ID}/providers/Microsoft.Compute/virtualMachineScaleSets/${SCALE_SET_NAME}/VirtualMachines/${VM_UUID};
RANCHER_COMMAND=`echo ${RANCHER_COMMAND} | sed -e 's@docker run@docker run -e CATTLE_AGENT_IP='"${VM_IP}"' -e CATTLE_HOST_LABELS=ressource_id='"${VM_ID}"'@g'`;

if [ ! "$(docker ps -q -f name=rancher/agent)" ]; then
    echo Starting the agent with the command line : ${RANCHER_COMMAND};
    eval ${RANCHER_COMMAND};
fi

waitDebconf;
echo 'debconf debconf/frontend select Dialog' | debconf-set-selections
