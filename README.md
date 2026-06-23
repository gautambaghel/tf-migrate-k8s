# tf-migrate-k8s

Utilities for migrating Terraform configurations from unversioned Kubernetes
provider resources to the versioned resource names required by newer
`hashicorp/kubernetes` releases.

This repository contains:

- a migration script that rewrites resource types such as
	`kubernetes_config_map` to `kubernetes_config_map_v1`
- mapping files used to infer old-to-new resource addresses
- a Copilot skill definition that documents the workflow for agent-driven use

The migration is config-based. Instead of mutating Terraform state directly,
the script adds `removed` and `import` blocks so the move works with local
state, remote backends, and Terraform Cloud or Terraform Enterprise.

## What the script does

The main entry point is
`scripts/migrate-kubernetes-versioned-resource.sh`.

When run against a Terraform configuration, it can:

1. Detect Kubernetes provider version constraints below `~> 3.0` and update
	 them to `~> 3.0`.
2. Rewrite unversioned `kubernetes_*` resource blocks in `.tf` files to their
	 versioned names.
3. Infer import IDs from `metadata` blocks where possible.
4. Append Terraform `removed` and `import` blocks for each migrated resource.
5. Run `terraform plan` to verify the migration result.

The expected post-migration plan should look like this:

```text
Plan: N to import, 0 to add, 0 to change, 0 to destroy.
```

If the plan shows destroys, stop and inspect the generated migration blocks or
the inferred import IDs before applying.

## Requirements

- `terraform` available in `PATH`
- `awk`, `find`, `grep`, `sed`, and standard Unix shell utilities
- Terraform configuration already checked out locally

## Quick start

Preview all detectable migrations without editing files:

```bash
scripts/migrate-kubernetes-versioned-resource.sh \
	--auto-discover \
	--discover-only \
	--dry-run
```

Apply config changes for all detected Kubernetes resources:

```bash
scripts/migrate-kubernetes-versioned-resource.sh --auto-discover
```

Verify the result:

```bash
terraform plan
```

## Explicit migration mode

If you already know the old and new Terraform addresses, run the script with
positional arguments:

```bash
scripts/migrate-kubernetes-versioned-resource.sh \
	kubernetes_config_map.example \
	kubernetes_config_map_v1.example \
	default/my-config
```

Arguments:

- `OLD_ADDRESS`: existing Terraform address
- `NEW_ADDRESS`: versioned Terraform address
- `IMPORT_ID`: optional import ID; if omitted, the script writes
	`<resource_id>` as a placeholder

In explicit mode, the script appends migration blocks to `main.tf` in the
target Terraform directory.

## Auto-discovery mode

Auto-discovery scans `.tf` files for Kubernetes resources and builds migration
candidates automatically.

```bash
scripts/migrate-kubernetes-versioned-resource.sh --auto-discover
```

Behavior:

- explicit address overrides from
	`scripts/kubernetes-versioned-address-map.txt` are applied first
- type mappings from `scripts/kubernetes-versioned-type-map.txt` are used next
- if no type mapping exists, the script falls back to appending `_v1`
- import IDs are inferred from `metadata.name` and `metadata.namespace` when
	possible

For auto-discovered versioned resources, migration blocks are appended to the
same `.tf` file that contains the resource block. Address-map-only entries are
currently appended to `main.tf`.

## Common options

```text
--terraform-dir DIR           Run Terraform from DIR. Default: current directory.
--auto-discover               Discover and migrate matching resources automatically.
--discover-only               Print discovered mappings but do not execute changes.
--skip-provider-version-bump  Leave the kubernetes provider constraint unchanged.
--skip-config-rewrite         Do not rename resource blocks in .tf files.
--address-map-file FILE       Override the address mapping file.
--type-map-file FILE          Override the type mapping file.
--skip-plan                   Skip terraform plan after config changes.
--dry-run                     Print actions without executing them.
```

## Mapping files

The repository includes two mapping inputs under `scripts/`:

- `kubernetes-versioned-type-map.txt`: maps unversioned resource types to their
	versioned replacements
- `kubernetes-versioned-address-map.txt`: optional exact address overrides for
	cases where name or module path inference is not enough

Example address override:

```text
module.platform.kubernetes_service.api=module.platform.kubernetes_service_v1.api
```

## Repository contents

```text
.
|-- README.md
|-- SKILL.md
`-- scripts/
		|-- kubernetes-versioned-address-map.txt
		|-- kubernetes-versioned-type-map.txt
		`-- migrate-kubernetes-versioned-resource.sh
```

## Copilot skill

`SKILL.md` packages the migration workflow as a reusable Copilot skill. If you
are using this repository from an agent-driven workflow, that file is the
instruction surface; the shell script in `scripts/` is the executable surface.

## Recommended workflow

1. Run `--auto-discover --discover-only --dry-run` and review the candidates.
2. Add any needed explicit overrides to
	 `scripts/kubernetes-versioned-address-map.txt`.
3. Run `--auto-discover` to apply the config changes.
4. Review the Terraform diff.
5. Run `terraform plan` and confirm there are imports only.
6. Apply through your normal Terraform workflow.