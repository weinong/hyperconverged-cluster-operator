#!/bin/bash

# Don't exit on error - we want to process all images even if some fail
set +e

# Script to update KubeVirt images in deploy/images.csv with custom registry, namespace, and tag
# Usage: ./update-kubevirt-images.sh <registry> <namespace> <tag>
# Example: ./update-kubevirt-images.sh quay.io kaizentm v1.6.0-custom

REGISTRY="${1:-quay.io/kubevirt}"
NAMESPACE="${2}"
TAG="${3}"

# Construct the full registry path
if [ -n "$NAMESPACE" ]; then
    FULL_REGISTRY="${REGISTRY}/${NAMESPACE}"
else
    FULL_REGISTRY="${REGISTRY}"
fi

# Validate inputs
if [ -z "$TAG" ]; then
    echo "Usage: $0 <registry> <namespace> <tag>"
    echo "Example: $0 quay.io kaizentm v1.6.0-custom"
    echo ""
    echo "Arguments:"
    echo "  registry:  Container registry (e.g., quay.io, ghcr.io)"
    echo "  namespace: Registry namespace/organization (e.g., kaizentm, myorg)"
    echo "  tag:       Image tag to use (e.g., v1.6.0-custom, latest)"
    exit 1
fi

echo "========================================"
echo "Updating KubeVirt images in images.csv"
echo "========================================"
echo "Registry:   $REGISTRY"
echo "Namespace:  $NAMESPACE"
echo "Full path:  $FULL_REGISTRY"
echo "Tag:        $TAG"
echo "========================================"
echo ""

# KubeVirt images to update (matching the CSV file)
KUBEVIRT_IMAGES=(
    "virt-operator"
    "virt-api"
    "virt-controller"
    "virt-launcher"
    "virt-handler"
    "virtio-container-disk"
    "libguestfs-tools"
    "virt-exportproxy"
    "virt-exportserver"
    "network-passt-binding"
    "network-passt-binding-cni"
    "pr-helper"
    "sidecar-shim"
    "virt-synchronization-controller"
)

# Build digester tool if not already built
DIGESTER_PATH="./tools/digester/digester"
if [ ! -f "$DIGESTER_PATH" ]; then
    echo "Building digester tool..."
    (cd tools/digester && go build .) || {
        echo "Error: Failed to build digester tool"
        exit 1
    }
    echo "✓ Digester tool built successfully"
    echo ""
fi

# Create a backup of the original CSV file
BACKUP_FILE="deploy/images.csv.backup.$(date +%Y%m%d_%H%M%S)"
cp deploy/images.csv "$BACKUP_FILE"
echo "✓ Backup created: $BACKUP_FILE"
echo ""

# Temporary file for building the new CSV
TEMP_CSV=$(mktemp)
cp deploy/images.csv "$TEMP_CSV"

# Process each KubeVirt image
echo "Fetching digests and updating CSV..."
SUCCESS_COUNT=0
FAIL_COUNT=0
FAILED_IMAGES=()

for image in "${KUBEVIRT_IMAGES[@]}"; do
    FULL_IMAGE="${FULL_REGISTRY}/${image}:${TAG}"
    echo -n "  Processing $image... "
    
    # Get the digest using the digester tool
    digest=$("$DIGESTER_PATH" -d --image "$FULL_IMAGE" 2>&1)
    exit_code=$?
    
    # Remove "sha256:" prefix if present (we just want the hash)
    digest=$(echo "$digest" | sed 's/^sha256://')
    
    if [ $exit_code -eq 0 ] && [ -n "$digest" ] && [[ ! "$digest" =~ "error" ]] && [[ ! "$digest" =~ "Error" ]]; then
        # Find the corresponding environment variable name in the CSV
        # Convert image name to uppercase and replace hyphens with underscores
        ENV_PREFIX=$(echo "$image" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
        
        # Map common image names to their environment variables (matching the CSV file exactly)
        case "$image" in
            "virt-operator")
                ENV_VAR="KUBEVIRT_OPERATOR_IMAGE"
                ;;
            "virt-api")
                ENV_VAR="KUBEVIRT_API_IMAGE"
                ;;
            "virt-controller")
                ENV_VAR="KUBEVIRT_CONTROLLER_IMAGE"
                ;;
            "virt-launcher")
                ENV_VAR="KUBEVIRT_LAUNCHER_IMAGE"
                ;;
            "virt-handler")
                ENV_VAR="KUBEVIRT_HANDLER_IMAGE"
                ;;
            "virtio-container-disk")
                ENV_VAR="KUBEVIRT_VIRTIO_IMAGE"
                ;;
            "libguestfs-tools")
                ENV_VAR="KUBEVIRT_LIBGUESTFS_TOOLS_IMAGE"
                ;;
            "virt-exportproxy")
                ENV_VAR="KUBEVIRT_EXPORTPROXY_IMAGE"
                ;;
            "virt-exportserver")
                ENV_VAR="KUBEVIRT_EXPORSERVER_IMAGE"
                ;;
            "network-passt-binding")
                ENV_VAR="NETWORK_PASST_BINDING_IMAGE"
                ;;
            "network-passt-binding-cni")
                ENV_VAR="NETWORK_PASST_BINDING_CNI_IMAGE"
                ;;
            "pr-helper")
                ENV_VAR="KUBEVIRT_PR_HELPER"
                ;;
            "sidecar-shim")
                ENV_VAR="KUBEVIRT_SIDECAR_SHIM"
                ;;
            "virt-synchronization-controller")
                ENV_VAR="KUBEVIRT_SYNC_CONTROLLER_IMAGE"
                ;;
            *)
                ENV_VAR="KUBEVIRT_${ENV_PREFIX}_IMAGE"
                ;;
        esac
        
        # Update the CSV file - replace the line matching the environment variable
        # CSV format: ENV_VAR,image_path,version_ref,digest
        sed -i "s|^${ENV_VAR},.*|${ENV_VAR},${FULL_REGISTRY}/${image},KUBEVIRT_VERSION,${digest}|" "$TEMP_CSV"
        
        echo "✓ digest: ${digest:0:12}..."
        ((SUCCESS_COUNT++))
    else
        echo "✗ FAILED (image not found or not accessible)"
        ((FAIL_COUNT++))
        FAILED_IMAGES+=("$image")
    fi
done

echo ""
echo "========================================"
echo "Summary"
echo "========================================"
echo "✓ Successfully updated: $SUCCESS_COUNT images"
echo "✗ Failed: $FAIL_COUNT images"

if [ $FAIL_COUNT -gt 0 ]; then
    echo ""
    echo "Failed images:"
    for failed in "${FAILED_IMAGES[@]}"; do
        echo "  - $failed"
    done
fi

echo ""

# Show changes before applying
echo "========================================"
echo "Changes Preview"
echo "========================================"
echo "Showing KubeVirt image lines that changed:"
echo ""
diff -u <(grep "^KUBEVIRT.*_IMAGE," deploy/images.csv | head -14) \
        <(grep "^KUBEVIRT.*_IMAGE," "$TEMP_CSV" | head -14) || true

echo ""
read -p "Apply these changes to deploy/images.csv? (y/n) " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    mv "$TEMP_CSV" deploy/images.csv
    echo "✓ Changes applied to deploy/images.csv"
    echo ""
    echo "Next steps:"
    echo "  1. Review the changes: git diff deploy/images.csv"
    echo "  2. Regenerate images.env: ./automation/digester/update_images.sh"
    echo "  3. Rebuild manifests: make build-manifests"
    echo ""
    echo "To restore the backup: cp $BACKUP_FILE deploy/images.csv"
else
    rm "$TEMP_CSV"
    echo "✗ Changes discarded"
    echo "Original file unchanged. Backup is still available at: $BACKUP_FILE"
fi
