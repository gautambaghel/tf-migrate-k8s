---
name: migrating-kubernetes-provider-resources
description: Migrate Terraform configs from the Kubernetes provider v2.x to v3.x by bumping the version constraint to ~> 3.0, renaming deprecated unversioned resources (e.g. kubernetes_config_map) to their versioned names (kubernetes_config_map_v1), and adding removed/import blocks so state moves cleanly. Use whenever the user upgrades the hashicorp/kubernetes provider, sees a "Deprecated; use <resource>_v1" warning, wants to move to versioned resource names, or mentions Terraform Kubernetes provider 3.0. Works with Terraform Cloud/Enterprise since it edits config instead of mutating local state.
---

# Migrating Kubernetes Provider Resources to v3 (Versioned Names)

The HashiCorp Kubernetes provider deprecated all unversioned resource names in
v3.0. Each `kubernetes_<x>` resource must move to its `kubernetes_<x>_v1`
(or `_v2`) equivalent. This skill automates that migration using config-based
`removed` + `import` blocks, which is safe for local state, remote state, and
Terraform Cloud/Enterprise (no `terraform state` mutation, no local state backup).

## When to use

- Upgrading `hashicorp/kubernetes` from `~> 2.x` to `~> 3.0`.
- A plan shows `Deprecated; use kubernetes_<x>_v1`.
- The user wants to rename unversioned resources to versioned names.

## What the migration does

1. Bumps the `kubernetes` provider constraint to `~> 3.0` if it is below 3.x.
2. Runs `terraform init -upgrade` to refresh the lock file (skipped if no bump).
3. Renames unversioned `kubernetes_*` resource blocks in `.tf` files to versioned names.
4. Appends `removed` + `import` blocks per migrated resource:

   ```hcl
   removed {
     from = kubernetes_config_map.example
     lifecycle {
       destroy = false
     }
   }

   import {
     to = kubernetes_config_map_v1.example
     id = "default/my-config"
   }
   ```

5. Runs `terraform plan` to confirm: expect `N to import, 0 to add, 0 to change, 0 to destroy`.

`removed` with `destroy = false` drops the old address from Terraform management
without deleting the live object; `import` adopts it under the new versioned address.

## Run the script

The workflow is implemented in
[scripts/migrate-kubernetes-versioned-resource.sh](../../../scripts/migrate-kubernetes-versioned-resource.sh).
Prefer running it over performing the steps by hand.

```bash
# Preview only — prints planned changes, edits nothing
scripts/migrate-kubernetes-versioned-resource.sh --auto-discover --discover-only --dry-run

# Apply config changes for every deprecated kubernetes resource found
scripts/migrate-kubernetes-versioned-resource.sh --auto-discover

# Verify
terraform plan
```

Single resource (when not auto-discovering):

```bash
scripts/migrate-kubernetes-versioned-resource.sh \
  kubernetes_config_map.example \
  kubernetes_config_map_v1.example \
  default/my-config
```

Useful flags:

- `--terraform-dir DIR` — run against another config directory.
- `--skip-provider-version-bump` — leave the version constraint untouched.
- `--skip-config-rewrite` — do not rename resource blocks.
- `--skip-plan` — skip the final `terraform plan`.
- `--dry-run` — print actions without writing files.

## Workflow checklist

```
- [ ] Step 1: Dry-run discovery to review planned changes
- [ ] Step 2: Run --auto-discover to apply config edits
- [ ] Step 3: Review the diff (resource renames + removed/import blocks)
- [ ] Step 4: Run terraform plan; confirm only imports, no destroys
- [ ] Step 5: Apply (terraform apply or via TFC/TFE run)
```

## Resource name mappings

Old to new type mappings come from the full v3 deprecation table in
[scripts/kubernetes-versioned-type-map.txt](../../../scripts/kubernetes-versioned-type-map.txt).
The script falls back to appending `_v1` for any type not listed.

Two special cases:

- `kubernetes_horizontal_pod_autoscaler` to `_v1` or `_v2` (map defaults to `_v2`).
- `kubernetes_pod_security_policy` is removed upstream; no replacement.

For renamed local names or module-scoped addresses, add explicit
`old_address=new_address` overrides in
[scripts/kubernetes-versioned-address-map.txt](../../../scripts/kubernetes-versioned-address-map.txt).
This file is optional and only needed when type-based inference is insufficient.

## Verifying

A successful migration produces a plan like:

```
Plan: 1 to import, 0 to add, 0 to change, 0 to destroy.
```

If the plan shows resources being destroyed, stop. The `removed`/`import` blocks
or the import `id` are wrong. Re-run with `--dry-run` to inspect before applying.

## Import IDs

The script infers the import `id` from the resource's `metadata` block
(`namespace/name`, or `name` for cluster-scoped resources). If it cannot infer
one, it writes a `<resource_id>` placeholder. Replace it with the real
Kubernetes ID before applying.
