# Rendered by scripts/bootstrap.sh (kyverno stage): the public-key placeholder below becomes infra/cosign/cosign.pub.
# Scope: only namespace "sdlc-apps", so cluster components can never be blocked by this lab policy.
apiVersion: policies.kyverno.io/v1
kind: ImageValidatingPolicy
metadata:
  name: require-signed-lab-images
spec:
  validationActions: [Deny]
  webhookConfiguration: {timeoutSeconds: 30}
  matchConstraints:
    namespaceSelector:
      matchLabels: {kubernetes.io/metadata.name: sdlc-apps}
    resourceRules:
      - apiGroups: [""]
        apiVersions: [v1]
        operations: [CREATE, UPDATE]
        resources: [pods]
  credentials:
    secrets: [harbor-robot]            # robot account in the kyverno namespace (read-only pull)
  matchImageReferences:
    - glob: "harbor.local:9443/poc/*"
  attestors:
    - name: labkey
      cosign:
        key:
          data: |-
__COSIGN_PUB__
        ctlog: {insecureIgnoreTlog: true, insecureIgnoreSCT: true}   # private lab: no public transparency log
  attestations:
    - name: sbom
      intoto: {type: https://spdx.dev/Document}
  validations:
    - expression: "images.containers.map(image, verifyImageSignatures(image, [attestors.labkey])).all(e, e > 0)"
      message: "Image is not signed by the lab key (cosign verification failed)."
    - expression: "images.containers.map(image, verifyAttestationSignatures(image, attestations.sbom, [attestors.labkey])).all(e, e > 0)"
      message: "Image has no SBOM attestation signed by the lab key."
---
# Pods in sdlc-apps may only use images from the lab registry (images outside the glob above are
# skipped by the policy, so this separate check closes that gap).
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: lab-registry-only
spec:
  validationActions: [Deny]
  matchConstraints:
    namespaceSelector:
      matchLabels: {kubernetes.io/metadata.name: sdlc-apps}
    resourceRules:
      - apiGroups: [""]
        apiVersions: [v1]
        operations: [CREATE, UPDATE]
        resources: [pods]
  validations:
    - expression: "object.spec.containers.all(c, c.image.startsWith('harbor.local:9443/poc/'))"
      message: "Images must come from harbor.local:9443/poc/ (the lab registry)."
