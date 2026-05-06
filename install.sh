#!/bin/bash
# Quick script to run Helm

set -e; set -o pipefail;

cd "$(dirname "$0")"

additional_flags=''
tools_additional_flags=''

if [[ "$1" == "-t" ]]; then
    additional_flags+=" --values additionalManifests.yaml --set tools.enabled=true"
fi

if [[ "$INSTALL_RHCL_GA" == "true" ]]; then
    additional_flags+=" --set kuadrant.indexImage='' --set kuadrant.operatorName=rhcl-operator --set kuadrant.channel=stable"
fi

if [[ "$FREEZE_VERSIONS" == "true" ]]; then
    script/get-all-versions.sh > "values-versions.yaml" || exit 1
    additional_flags+=" --values values-versions.yaml"
    tools_additional_flags+=" --values values-versions.yaml"
fi

echo "---Installing operators---"
helm_cmd="helm install $additional_flags --wait kuadrant-operators charts/kuadrant-operators"
eval "$helm_cmd"

echo "--Installing instances---"
helm_cmd="helm install $additional_flags --wait kuadrant-instances charts/kuadrant-instances"
eval "$helm_cmd"

if [[ "$1" == "-t" ]]; then
echo "--Installing tools operators"
helm_cmd="helm install $tools_additional_flags --wait tools-operators charts/tools-operators"
eval "$helm_cmd"

echo "--Installing tools instances"
helm_cmd="helm install $tools_additional_flags --wait --timeout 10m tools-instances charts/tools-instances"
eval "$helm_cmd"
fi

echo "Success!"
