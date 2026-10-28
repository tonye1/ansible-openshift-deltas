#!/usr/bin/env bash
# prepare-locust-token.sh
#
# Creates an OpenShift Secret containing the current oc bearer token so that
# Locust workers inside the cluster can authenticate to the RHOAI inference
# endpoint without embedding a static token in the ConfigMap.
#
# Run this on the bastion (<bastion-host>) after 'oc login':
#   bash prepare-locust-token.sh
#
# The token is short-lived (~24 h). Re-run after each oc login refresh.

set -euo pipefail

TOKEN=$(oc whoami -t)

oc create secret generic locust-token-secret \
  -n locust \
  --from-literal=token="${TOKEN}" \
  --dry-run=client -o yaml | oc apply -f -

echo "Secret 'locust-token-secret' created/updated in namespace 'locust'."
echo "Workers will pick it up on next pod restart:"
echo "  oc rollout restart deployment/locust-worker -n locust"
