---
name: tf-migrate-k8s
description: >-
  **UTILITY SKILL** — Migrate Terraform Kubernetes provider configs from v2.x to
  v3.x. Run the bundled script to move deprecated unversioned resources to their
  versioned _v1 equivalents and add removed/import blocks, then verify a plan
  with zero destroys. USE FOR: upgrading hashicorp/kubernetes to 3.0, moving
  unversioned resources like kubernetes_config_map to versioned names such as
  kubernetes_config_map_v1, HCP Terraform or Enterprise migrations. DO NOT USE
  FOR: non-Kubernetes providers, authoring new resources, manual state surgery
  (terraform state rm), provider downgrades, changes unrelated to
  versioned-resource renames. INVOKES: scripts/migrate-kubernetes-versioned-resource.sh.
license: Apache-2.0
metadata:
  version: 1.0.0
---

# Migrate Kubernetes Provider Resources to v3

The hashicorp/kubernetes provider v3.0 deprecated every unversioned resource
name; each must move to its versioned name (kubernetes_config_map becomes
kubernetes_config_map_v1). This skill automates it with config-based removed +
import blocks — safe for local, remote, and HCP Terraform / Enterprise state.

## Requirements

Terraform >= 1.7 (import alone needs 1.5) and bash 4+.

## Run the script

Prefer the script over manual edits:
[scripts/migrate-kubernetes-versioned-resource.sh](scripts/migrate-kubernetes-versioned-resource.sh).
It bumps the constraint to ~> 3.0, renames resource blocks, and appends one
removed (destroy = false) plus import pair per resource.

```bash
# Preview changes (writes nothing)
scripts/migrate-kubernetes-versioned-resource.sh --auto-discover --discover-only --dry-run
# Apply, then verify (expect "N to import, 0 to add, 0 to change, 0 to destroy")
scripts/migrate-kubernetes-versioned-resource.sh --auto-discover && terraform plan
```

## Example

```hcl
removed {
  from = kubernetes_config_map.example
  lifecycle { destroy = false }
}
import {
  to = kubernetes_config_map_v1.example
  id = "default/my-config"
}
```

## Workflow

1. Dry-run discovery to review changes.
2. Run --auto-discover to apply edits.
3. Review the diff (renames plus removed/import blocks).
4. Confirm only imports, no destroys (terraform plan, or tfctl for TFC/TFE).
5. Apply (terraform apply, or approve the remote run).

## Troubleshooting

- Plan shows destroys: stop — a removed/import block or import id is wrong;
  re-run with --dry-run to inspect.
- Import id is a placeholder: replace it with the live object's id
  (`namespace/name`, or `name` if cluster-scoped); find it with
  `kubectl get <kind> -A`.

## References

- [HCP Terraform / Enterprise with tfctl](references/hcp-terraform-tfctl.md)
- [Resource name mappings and special cases](references/resource-mappings.md)
- [Script options and verification](references/script-options.md)
