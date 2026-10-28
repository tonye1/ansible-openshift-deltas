#!/usr/bin/env bash
set -euo pipefail

TARGET_BASE="/var/www/html/repos/rhel9-s390x"
ARCH="s390x"

REPOS=(
    "rhel-9-for-s390x-baseos-rpms"
    "rhel-9-for-s390x-appstream-rpms"
    "codeready-builder-for-rhel-9-s390x-rpms"
)

# Install prerequisite tools if missing
dnf install -y dnf-plugins-core createrepo_c

for repo in "${REPOS[@]}"; do
    echo "=========================================="
    echo "Syncing repository: ${repo}"
    echo "=========================================="
    
    # Mirror packages & metadata
    dnf reposync \
        --repo="${repo}" \
        --arch="${ARCH}" \
        --arch="noarch" \
        --download-metadata \
        --delete \
        --download-path="${TARGET_BASE}"

    # Generate repository metadata if not present
    if [ -d "${TARGET_BASE}/${repo}" ]; then
        createrepo_c --update "${TARGET_BASE}/${repo}"
    fi
done

echo "[SUCCESS] All s390x repositories synchronized to ${TARGET_BASE}"
