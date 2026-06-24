# Script options and verification

## Single resource (when not auto-discovering)

```bash
scripts/migrate-kubernetes-versioned-resource.sh \
  kubernetes_config_map.example \
  kubernetes_config_map_v1.example \
  default/my-config
```

## Useful flags

- `--terraform-dir DIR` — run against another config directory.
- `--skip-provider-version-bump` — leave the version constraint untouched.
- `--skip-config-rewrite` — do not rename resource blocks.
- `--skip-plan` — skip the final `terraform plan`.
- `--dry-run` — print actions without writing files.
- `--use-tfctl` — verify against HCP Terraform / Terraform Enterprise with the
  `tfctl` CLI (see [hcp-terraform-tfctl.md](hcp-terraform-tfctl.md)).

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
one, it writes a placeholder. Replace it with the real Kubernetes ID before
applying.
