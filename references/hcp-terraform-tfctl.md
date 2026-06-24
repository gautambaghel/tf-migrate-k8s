# HCP Terraform / Terraform Enterprise (tfctl)

The migration is config-based, so it is already safe for workspaces whose state
lives in HCP Terraform or Terraform Enterprise — it never mutates local state.
When a `cloud {}` or `backend "remote"` block is present, the script detects it
and reports the organization, hostname, and workspace.

Pass `--use-tfctl` to verify against the remote workspace with the official
[`tfctl` CLI](https://github.com/hashicorp/tfctl-cli):

```bash
scripts/migrate-kubernetes-versioned-resource.sh --auto-discover --use-tfctl
```

With `--use-tfctl`:

- `tfctl` is required; `terraform` becomes optional (steps that need it are
  skipped with a warning when it is absent).
- The script checks `tfctl auth status`, warns if the workspace Terraform
  version is too old (`import` needs >= 1.5, `removed` needs >= 1.7), and reports
  the latest run via `tfctl run status`.
- Add `--tfc-start-run` to start a remote run. The run uses the configuration
  version already in the workspace, so push (VCS) or run a CLI plan first.
- `--tfc-workspace`, `--tfc-organization`, `--tfc-hostname`, and `--tfc-message`
  override values that are otherwise read from the cloud block or tfctl profile.

Configure tfctl before running:

```bash
tfctl profile set hostname tfe.example.com   # omit for HCP Terraform
tfctl profile set default_organization my-org
tfctl auth login
```
