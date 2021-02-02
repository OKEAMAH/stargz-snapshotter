#!/bin/bash

#   Copyright The containerd Authors.

#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at

#       http://www.apache.org/licenses/LICENSE-2.0

#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

set -euo pipefail

CONTEXT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )/"
REPO="${CONTEXT}../../"
REGISTRY_HOST=registry-optimize
REPO_PATH=/go/src/github.com/containerd/stargz-snapshotter
DUMMYUSER=dummyuser
DUMMYPASS=dummypass
OPTIMIZE_BASE_IMAGE_NAME="optimize-image-base"
OPTIMIZE_TEST_IMAGE_NAME="optimize-image-test"
CNI_VERSION="v0.9.0"

source "${REPO}/script/util/utils.sh"

if [ "${OPTIMIZE_NO_RECREATE:-}" != "true" ] ; then
    echo "Preparing node image..."

    # Enable to check race
    docker build ${DOCKER_BUILD_ARGS:-} -t "${OPTIMIZE_BASE_IMAGE_NAME}" \
           --target snapshotter-base \
           --build-arg=SNAPSHOTTER_BUILD_FLAGS="-race" \
           "${REPO}"
fi

DOCKER_COMPOSE_YAML=$(mktemp)
AUTH_DIR=$(mktemp -d)
TMP_CONTEXT=$(mktemp -d)
function cleanup {
    local ORG_EXIT_CODE="${1}"
    rm "${DOCKER_COMPOSE_YAML}" || true
    rm -rf "${AUTH_DIR}" || true
    rm -rf "${TMP_CONTEXT}" || true
    exit "${ORG_EXIT_CODE}"
}
trap 'cleanup "$?"' EXIT SIGHUP SIGINT SIGQUIT SIGTERM

cat <<'EOF' > "${TMP_CONTEXT}/test.conflist"
{
  "cniVersion": "0.4.0",
  "name": "test",
  "plugins" : [{
    "type": "bridge",
    "bridge": "test0",
    "isDefaultGateway": true,
    "forceAddress": false,
    "ipMasq": true,
    "hairpinMode": true,
    "ipam": {
      "type": "host-local",
      "subnet": "10.10.0.0/16"
    }
  },
  {
    "type": "loopback"
  }]
}
EOF

cat <<EOF > "${TMP_CONTEXT}/Dockerfile"
# Legacy builder that doesn't support TARGETARCH should set this explicitly using --build-arg.
# If TARGETARCH isn't supported by the builder, the default value is "amd64".

FROM ${OPTIMIZE_BASE_IMAGE_NAME}
ARG TARGETARCH

RUN apt-get update -y && \
    apt-get --no-install-recommends install -y jq iptables && \
    GO111MODULE=on go get github.com/google/go-containerregistry/cmd/crane && \
    mkdir -p /opt/tmp/cni/bin /etc/tmp/cni/net.d && \
    curl -Ls https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-\${TARGETARCH:-amd64}-${CNI_VERSION}.tgz | tar xzv -C /opt/tmp/cni/bin

# Installs CNI-related files to irregular paths (/opt/tmp/cni/bin and /etc/tmp/cni/net.d) for test.
# see entrypoint.sh for more details.

COPY ./test.conflist /etc/tmp/cni/net.d/test.conflist

EOF
docker build -t "${OPTIMIZE_TEST_IMAGE_NAME}" ${DOCKER_BUILD_ARGS:-} "${TMP_CONTEXT}"

echo "Preparing creds..."
prepare_creds "${AUTH_DIR}" "${REGISTRY_HOST}" "${DUMMYUSER}" "${DUMMYPASS}"

echo "Testing..."
function test_optimize {
    local OPTIMIZE_COMMAND="${1}"
    local NO_OPTIMIZE_COMMAND="${2}"
    cat <<EOF > "${DOCKER_COMPOSE_YAML}"
version: "3.3"
services:
  docker_opt:
    image: docker:dind
    container_name: docker
    privileged: true
    environment:
    - DOCKER_TLS_CERTDIR=/certs
    entrypoint:
    - sh
    - -c
    - |
      mkdir -p /etc/docker/certs.d/${REGISTRY_HOST}:5000 && \
      cp /registry/certs/domain.crt /etc/docker/certs.d/${REGISTRY_HOST}:5000 && \
      dockerd-entrypoint.sh
    volumes:
    - docker-client:/certs/client
    - ${AUTH_DIR}:/registry:ro
  testenv_opt:
    image: ${OPTIMIZE_TEST_IMAGE_NAME}
    container_name: testenv_opt
    privileged: true
    working_dir: ${REPO_PATH}
    entrypoint: ./script/optimize/optimize/entrypoint.sh
    environment:
    - NO_PROXY=127.0.0.1,localhost,${REGISTRY_HOST}:5000
    - DOCKER_HOST=tcp://docker:2376
    - DOCKER_TLS_VERIFY=1
    - OPTIMIZE_COMMAND=${OPTIMIZE_COMMAND}
    - NO_OPTIMIZE_COMMAND=${NO_OPTIMIZE_COMMAND}
    tmpfs:
    - /tmp:exec,mode=777
    volumes:
    - "${REPO}:${REPO_PATH}:ro"
    - ${AUTH_DIR}:/auth:ro
    - docker-client:/docker/client:ro
    - "optimize-containerd-data:/var/lib/containerd"
    - "optimize-containerd-stargz-grpc-data:/var/lib/containerd-stargz-grpc"
  registry:
    image: registry:2
    container_name: ${REGISTRY_HOST}
    environment:
    - REGISTRY_AUTH=htpasswd
    - REGISTRY_AUTH_HTPASSWD_REALM="Registry Realm"
    - REGISTRY_AUTH_HTPASSWD_PATH=/auth/auth/htpasswd
    - REGISTRY_HTTP_TLS_CERTIFICATE=/auth/certs/domain.crt
    - REGISTRY_HTTP_TLS_KEY=/auth/certs/domain.key
    volumes:
    - ${AUTH_DIR}:/auth:ro
volumes:
  docker-client:
  optimize-containerd-data:
  optimize-containerd-stargz-grpc-data:
EOF
    local FAIL=
    if ! ( cd "${CONTEXT}" && \
               docker-compose -f "${DOCKER_COMPOSE_YAML}" build ${DOCKER_BUILD_ARGS:-} testenv_opt && \
               docker-compose -f "${DOCKER_COMPOSE_YAML}" up --abort-on-container-exit ) ; then
        FAIL=true
    fi
    docker-compose -f "${DOCKER_COMPOSE_YAML}" down -v
    if [ "${FAIL}" == "true" ] ; then
        exit 1
    fi
}

test_optimize "image optimize --oci" "image optimize --no-optimize --oci"

exit 0
