#!/bin/bash

set -e

if [[ -z "${1}" ]]; then
    echo "need version"
    exit
fi

IMAGE_VERSION="${1:-latest}"
STAGING_REGISTRY="us-central1-docker.pkg.dev/eclipse-362422/eclipse-docker-apps"
DEV_REGISTRY="us-central1-docker.pkg.dev/eclipse-dev-385408/eclipse-docker-apps"
IMAGE_NAME="neon-faucet"

# us-central1-docker.pkg.dev/eclipse-dev-385408/eclipse-docker-apps/neon-faucet:latest

docker build --progress=plain -f "Dockerfile" -t "${IMAGE_NAME}:${IMAGE_VERSION}" .

# login artifacts
gcloud auth print-access-token | docker login -u oauth2accesstoken --password-stdin "https://us-central1-docker.pkg.dev"

# push to staging registry
push_targe="${STAGING_REGISTRY}/${IMAGE_NAME}:${IMAGE_VERSION}"
echo "push to ${push_targe}"
docker tag "${IMAGE_NAME}:${IMAGE_VERSION}" "${push_targe}"
docker push "${push_targe}"

# push to dev registry
push_targe="${DEV_REGISTRY}/${IMAGE_NAME}:${IMAGE_VERSION}"
echo "push to ${push_targe}"
docker tag "${IMAGE_NAME}:${IMAGE_VERSION}" "${push_targe}"
docker push "${push_targe}"
