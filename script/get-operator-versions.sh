#!/bin/bash
# Requires jq and opm
# Requires podman to be authenticated to registry.redhat.io
# Resolves newest operator CSV versions from the Red Hat operator index catalog specified in env CATALOG_IMAGE,
# Picks biggest semantically version as latest

set -euo pipefail

CATALOG_IMAGE="${CATALOG_IMAGE:-registry.redhat.io/redhat/redhat-operator-index:v4.22}"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Filter only relevant channels and bundles from the catalog.
opm render "$CATALOG_IMAGE" 2>/dev/null | jq -c '
  select(
    (.schema == "olm.channel" and (
      (.package == "openshift-cert-manager-operator" and .name == "stable-v1") or
      (.package == "rhbk-operator" and (.name | test("^stable-v[0-9]+$"))) or
      (.package == "servicemeshoperator3" and .name == "stable")
    )) or
    (.schema == "olm.bundle" and .package == "servicemeshoperator3")
  )
' > "$tmpdir/catalog.jsonl"

if [[ ! -s "$tmpdir/catalog.jsonl" ]]; then
    echo "ERROR: Failed to render or filter catalog ${CATALOG_IMAGE}" >&2
    exit 1
fi

# Sort and select latest versions of operators and their dependencies from the catalog outputting as JSON object.
# Specific channels are used for each operator
result=$(jq -s -c '
  def semver_tuple($v):
    ($v | ltrimstr("v") | split(".") | map(tonumber));

  def csv_semver_key($csv):
    ($csv | capture("\\.v(?<ver>[0-9]+\\.[0-9]+\\.[0-9]+)") | .ver) as $ver | semver_tuple($ver);

  def keycloak_key($csv):
    ($csv | capture("\\.v(?<base>[0-9]+\\.[0-9]+\\.[0-9]+)-opr\\.(?<suffix>[0-9]+)") |
      (.base | split(".") | map(tonumber)) + [(.suffix | tonumber)]);

  def istiod_version($name):
    ($name | capture("^images_v(?<maj>[0-9]+)_(?<min>[0-9]+)_(?<pat>[0-9]+)_istiod$") |
      "v\(.maj).\(.min).\(.pat)");

  . as $objects
  | [$objects[] | select(.schema == "olm.channel" and .package == "openshift-cert-manager-operator" and .name == "stable-v1") | .entries[].name] as $cert_csvs
  | [$objects[] | select(.schema == "olm.channel" and .package == "rhbk-operator" and (.name | test("^stable-v[0-9]+$"))) | .entries[].name] as $keycloak_csvs
  | [$objects[] | select(.schema == "olm.channel" and .package == "servicemeshoperator3" and .name == "stable") | .entries[].name] as $istio_csvs
  | ($cert_csvs | unique | sort_by(csv_semver_key(.)) | last) as $cert_csv
  | ($keycloak_csvs | unique | sort_by(keycloak_key(.)) | last) as $keycloak_csv
  | ($istio_csvs | unique | sort_by(csv_semver_key(.)) | last) as $istio_csv
  | [$objects[] | select(.schema == "olm.bundle" and .name == $istio_csv) | .relatedImages[]?.name | select(test("_istiod$")) | istiod_version(.)] as $istio_versions
  | ($istio_versions | unique | sort_by(. as $v | semver_tuple($v)) | last) as $istio_version
  | ($keycloak_csv | if . then capture("\\.v(?<ver>[0-9]+\\.[0-9]+\\.[0-9]+)-opr\\.(?<suffix>[0-9]+)") else null end) as $keycloak_parts
  | {
      cert_csv: $cert_csv,
      keycloak_csv: $keycloak_csv,
      keycloak_major: (if $keycloak_parts then ($keycloak_parts.ver | split(".")[0]) else null end),
      istio_csv: $istio_csv,
      istio_version: $istio_version
    }
' "$tmpdir/catalog.jsonl")

cert_csv=$(jq -r '.cert_csv // empty' <<< "$result")
keycloak_csv=$(jq -r '.keycloak_csv // empty' <<< "$result")
keycloak_major=$(jq -r '.keycloak_major // empty' <<< "$result")
istio_csv=$(jq -r '.istio_csv // empty' <<< "$result")
istio_version=$(jq -r '.istio_version // empty' <<< "$result")

failed=()
[[ -z "$cert_csv" ]] && failed+=("cert-manager")
[[ -z "$keycloak_csv" ]] && failed+=("keycloak")
[[ -z "$istio_csv" ]] && failed+=("servicemesh (ossm3) operator")
[[ -z "$istio_version" ]] && failed+=("istio version")

if [[ ${#failed[@]} -gt 0 ]]; then
    echo "ERROR: Failed to resolve versions for: ${failed[*]}" >&2
    exit 1
fi

cat <<EOF
certManager:
  operator:
    startingCSV: ${cert_csv}
    installPlanApproval: Manual
tools:
  keycloak:
    operator:
      channel: stable-v${keycloak_major}
      startingCSV: ${keycloak_csv}
      installPlanApproval: Manual
istio:
  ossm3:
    operator:
      startingCSV: ${istio_csv}
      installPlanApproval: Manual
    version: ${istio_version}
EOF
