# Using Custom KubeVirt Images and Fork

This document describes how to integrate a custom KubeVirt fork and custom container images into the HyperConverged Cluster Operator (HCO).

## Overview

The HCO manages multiple KubeVirt components and can be configured to use custom builds of KubeVirt, including:
- Custom KubeVirt API/client-go modules from a fork
- Custom container images from a private registry

## Prerequisites

- Custom KubeVirt fork with your modifications
- Custom KubeVirt container images built and pushed to a registry
- Image tags and registry information
- Access to the digester tool (`tools/digester/digester`)

## Step 1: Update Go Modules to Use Custom Fork

Update `go.mod` to replace the official KubeVirt modules with your fork using replace directives:

```go
replace kubevirt.io/api => github.com/YOUR_FORK/kubevirt/staging/src/kubevirt.io/api v0.0.0-COMMIT_TIMESTAMP-COMMIT_SHA
replace kubevirt.io/client-go => github.com/YOUR_FORK/kubevirt/staging/src/kubevirt.io/client-go v0.0.0-COMMIT_TIMESTAMP-COMMIT_SHA
```

Example:
```go
replace kubevirt.io/api => github.com/kaizentm/kubevirt/staging/src/kubevirt.io/api v0.0.0-20251002190125-63cf660464c2
replace kubevirt.io/client-go => github.com/kaizentm/kubevirt/staging/src/kubevirt.io/client-go v0.0.0-20251002190125-63cf660464c2
```

### Generating Pseudo-Versions

The pseudo-version format is `v0.0.0-YYYYMMDDHHMMSS-COMMITHASH` (12 characters of commit hash).

Example from commit `63cf660464c27b2ae6335118b197edf1124ba285` created on October 2, 2025 at 19:01:25 UTC:
- Pseudo-version: `v0.0.0-20251002190125-63cf660464c2`

After updating `go.mod`, run:
```bash
go mod tidy
go mod vendor
```

## Step 2: Update KubeVirt Version Configuration

Update the `KUBEVIRT_VERSION` in `hack/config` to match your custom image tag:

```bash
KUBEVIRT_VERSION="1.6.0-l1vh.127"  # Use your custom tag
```

**Important:** Remove the `v` prefix if your tag doesn't include it.

## Step 3: Update KubeVirt Container Images

### Automated Method (Recommended)

Use the provided `update-kubevirt-images.sh` script:

```bash
./update-kubevirt-images.sh <registry> <namespace> <tag>
```

Example:
```bash
./update-kubevirt-images.sh arol1vh.azurecr.io kaizentm/kubevirt 1.6.0-l1vh.127
```

The script will:
1. Fetch image digests from your registry using the digester tool
2. Update all 14 KubeVirt images in `deploy/images.csv`
3. Show a preview of changes
4. Ask for confirmation before applying changes

### KubeVirt Images Updated

The following images are replaced:
- `virt-operator`
- `virt-api`
- `virt-controller`
- `virt-handler`
- `virt-launcher`
- `virt-exportproxy`
- `virt-exportserver`
- `virt-synchronization-controller`
- `libguestfs-tools`
- `virtio-container-disk`
- `pr-helper`
- `sidecar-shim`
- `network-passt-binding`
- `network-passt-binding-cni`

## Step 4: Build Manifests

Build the operator manifests with your custom images:

```bash
make build-manifests
```

**Note:** If your KubeVirt fork includes API changes (new fields, scheduling modifications, etc.), you may see CSV diff errors. In this case, use:

```bash
SKIP_CSV_DIFF=true make build-manifests
```

### Expected Changes from Custom Fork

If your KubeVirt fork includes modifications beyond just custom builds, you may see additional changes in the generated manifests:

1. **CRD Changes** (`deploy/crds/kubevirt00.crd.yaml`):
   - New API fields (e.g., `hypervisorConfiguration`)
   - New architecture support (e.g., s390x)
   - Deprecated architectures (e.g., ppc64le)

2. **CSV Changes** (`deploy/olm-catalog/.../kubevirt-hyperconverged-operator.*.clusterserviceversion.yaml`):
   - Modified RBAC permissions
   - Node affinity rules
   - Pod tolerations
   - Image references

These changes are expected and should be committed as part of your custom build.

## Step 5: Build and Deploy

Build the operator image with your changes:

```bash
export IMAGE_REGISTRY=arol1vh.azurecr.io
export REGISTRY_NAMESPACE=kubevirt
export IMAGE_TAG=1.6.0-l1vh.127

# build the container images and push them to registry
make container-build container-build-artifacts-server container-push

export HCO_OPERATOR_IMAGE=$IMAGE_REGISTRY/$REGISTRY_NAMESPACE/hyperconverged-cluster-operator:$IMAGE_TAG
export HCO_WEBHOOK_IMAGE=$IMAGE_REGISTRY/$REGISTRY_NAMESPACE/hyperconverged-cluster-webhook:$IMAGE_TAG
export ARTIFACTS_SERVER_IMAGE=$IMAGE_REGISTRY/$REGISTRY_NAMESPACE/virt-artifacts-server:$IMAGE_TAG

export PACKAGE_DIR="./deploy/olm-catalog/community-kubevirt-hyperconverged"
export CSV_VERSION=$(ls -d ${PACKAGE_DIR}/*/ | sort -rV | awk "NR==1" | cut -d '/' -f 5)

# Image to be used in CSV manifests
HCO_OPERATOR_IMAGE=$HCO_OPERATOR_IMAGE CSV_VERSION=$CSV_VERSION make build-manifests
sed -i "s|+WEBHOOK_IMAGE_TO_REPLACE+|${HCO_WEBHOOK_IMAGE}|g" deploy/index-image/community-kubevirt-hyperconverged/1.17.0/manifests/kubevirt-hyperconverged-operator.v1.17.0.clusterserviceversion.yaml
sed -i "s|+ARTIFACTS_SERVER_IMAGE_TO_REPLACE+|${ARTIFACTS_SERVER_IMAGE}|g" deploy/index-image/community-kubevirt-hyperconverged/1.17.0/manifests/kubevirt-hyperconverged-operator.v1.17.0.clusterserviceversion.yaml

./operator-sdk generate bundle --input-dir deploy/index-image/ --output-dir _out/bundle
./operator-sdk bundle validate _out/bundle  # optional
cd deploy/index-image && docker build -f bundle.Dockerfile -t $IMAGE_REGISTRY/$REGISTRY_NAMESPACE/hyperconverged-cluster-index:$IMAGE_TAG . && cd -
docker push $IMAGE_REGISTRY/$REGISTRY_NAMESPACE/hyperconverged-cluster-index:$IMAGE_TAG
# operator-sdk bundle validate $IMAGE_REGISTRY/$REGISTRY_NAMESPACE/hyperconverged-cluster-index:$IMAGE_TAG

oc create ns kubevirt-hyperconverged
./operator-sdk run bundle -n kubevirt-hyperconverged $IMAGE_REGISTRY/$REGISTRY_NAMESPACE/hyperconverged-cluster-index:$IMAGE_TAG --security-context-config restricted --verbose --timeout 5m

oc -n kubevirt-hyperconverged delete operatorgroup kubevirt-hyperconverged-group
oc -n kubevirt-hyperconverged delete subscription kubevirt-hyperconverged-operator-v1-17-0-sub
oc -n kubevirt-hyperconverged delete operator community-kubevirt-hyperconverged.kubevirt-hyperconverged
oc -n kubevirt-hyperconverged delete catalogsource community-kubevirt-hyperconverged-catalog
oc -n kubevirt-hyperconverged delete csv kubevirt-hyperconverged-operator.v1.17.0
```

To clean up:

```bash
oc delete ns kubevirt-hyperconverged
```

## Verification

After deployment, verify that your custom images are being used:

1. Check the HCO deployment:
   ```bash
   kubectl get deployment -n kubevirt-hyperconverged hyperconverged-cluster-operator -o yaml | grep image:
   ```

2. Check KubeVirt operator deployment:
   ```bash
   kubectl get deployment -n kubevirt-hyperconverged virt-operator -o yaml | grep image:
   ```

3. Verify KubeVirt version:
   ```bash
   kubectl get kubevirt -n kubevirt-hyperconverged kubevirt-kubevirt-hyperconverged -o yaml | grep observedKubeVirtVersion
   ```

## Reference Files

- **Go modules**: `go.mod`, `go.sum`
- **Version config**: `hack/config`
- **Image registry**: `deploy/images.csv`
- **Generated images**: `deploy/images.env`
- **CRDs**: `deploy/crds/kubevirt00.crd.yaml`
- **CSV**: `deploy/olm-catalog/community-kubevirt-hyperconverged/*/manifests/kubevirt-hyperconverged-operator.*.clusterserviceversion.yaml`
- **Update script**: `update-kubevirt-images.sh`

## Notes

- The digester tool requires network access to your container registry
- Image digests are required for OLM deployments
- Custom fork API changes will propagate through vendored dependencies
- All manifest changes should be committed to maintain consistency
- Consider documenting your fork's specific modifications for team reference
