#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/migrate-kubernetes-versioned-resource.sh [options] OLD_ADDRESS NEW_ADDRESS [IMPORT_ID]
  scripts/migrate-kubernetes-versioned-resource.sh [options] --auto-discover

Example:
  scripts/migrate-kubernetes-versioned-resource.sh \
    kubernetes_config_map.example \
    kubernetes_config_map_v1.example \
    default/my-config

What this does:
  1. Verifies Terraform is available.
  2. Optionally bumps Kubernetes provider version constraints to ~> 3.0.
  3. Rewrites unversioned kubernetes_* resources to versioned names.
  4. Adds Terraform removed/import blocks for each migration.
  5. Optionally runs terraform plan to confirm the migration.

Auto-discover mode:
  - Scans all .tf files for kubernetes resource blocks.
  - Applies explicit old_address=new_address overrides first.
  - Infers new type names using a mapping file + _v1 fallback.
  - Writes removed/import blocks to config instead of mutating state.

This is intended for Kubernetes provider upgrades from ~> 2.0 to ~> 3.0 and
later, after you have already updated your configuration to use the versioned
resource name documented by HashiCorp.

Options:
  --terraform-dir DIR   Run Terraform from DIR. Default: current directory.
  --auto-discover       Discover and migrate matching resources automatically.
  --discover-only       Print discovered mappings but do not execute changes.
  --skip-provider-version-bump
                        Do not auto-update kubernetes provider to ~> 3.0.
  --skip-config-rewrite
                        Do not auto-rewrite unversioned kubernetes resources in .tf files.
  --address-map-file FILE
                        Override address mapping file.
  --type-map-file FILE  Override type mapping file.
  --skip-plan           Skip terraform plan after config changes.
  --dry-run             Print the commands without executing them.
  -h, --help            Show this help message.

HCP Terraform / Terraform Enterprise (via the tfctl CLI):
  This migration is config-based (removed/import blocks), so it never mutates
  local state and works with workspaces whose state lives in HCP Terraform or
  Terraform Enterprise. When a cloud {} or remote backend block is present,
  pass --use-tfctl to verify the migration remotely with tfctl instead of (or
  in addition to) a local terraform plan.

  --use-tfctl           Verify against HCP Terraform / Terraform Enterprise with
                        tfctl. Requires the tfctl CLI; terraform becomes optional.
  --tfc-workspace NAME  Target workspace name. Defaults to the name in the
                        cloud/remote backend block, or tfctl's own resolution.
  --tfc-organization NAME
                        Organization name. Defaults to the cloud block value or
                        the active tfctl profile / TFCTL_ORGANIZATION.
  --tfc-hostname HOST   HCP Terraform / TFE hostname. Defaults to the cloud block
                        value or the active tfctl profile / TFCTL_HOSTNAME.
  --tfc-start-run       Start a remote run with tfctl after preparing config.
                        The run uses the latest uploaded configuration version,
                        so push (VCS) or upload (CLI plan) the migrated config first.
  --tfc-message MSG     Message to attach to the tfctl run.
EOF
}

terraform_dir="."
auto_discover=0
discover_only=0
address_map_file="scripts/kubernetes-versioned-address-map.txt"
type_map_file="scripts/kubernetes-versioned-type-map.txt"
skip_provider_version_bump=0
skip_config_rewrite=0
skip_plan=0
dry_run=0
provider_version_bumped=0
config_rewritten=0
use_tfctl=0
tfc_workspace=""
tfc_organization=""
tfc_hostname=""
tfc_start_run=0
tfc_message=""
tfc_detected=0
tfc_detected_org=""
tfc_detected_hostname=""
tfc_detected_workspace=""
terraform_available=0
tfctl_ctx_org=""
tfctl_ctx_host=""

declare -a candidates_file
candidates_file=""

declare -A address_map
declare -A type_map

while [[ $# -gt 0 ]]; do
  case "$1" in
    --terraform-dir)
      terraform_dir="$2"
      shift 2
      ;;
    --auto-discover)
      auto_discover=1
      shift
      ;;
    --discover-only)
      discover_only=1
      shift
      ;;
    --skip-provider-version-bump)
      skip_provider_version_bump=1
      shift
      ;;
    --skip-config-rewrite)
      skip_config_rewrite=1
      shift
      ;;
    --address-map-file)
      address_map_file="$2"
      shift 2
      ;;
    --type-map-file)
      type_map_file="$2"
      shift 2
      ;;
    --skip-plan)
      skip_plan=1
      shift
      ;;
    --use-tfctl)
      use_tfctl=1
      shift
      ;;
    --tfc-workspace)
      tfc_workspace="$2"
      shift 2
      ;;
    --tfc-organization)
      tfc_organization="$2"
      shift 2
      ;;
    --tfc-hostname)
      tfc_hostname="$2"
      shift 2
      ;;
    --tfc-start-run)
      tfc_start_run=1
      shift
      ;;
    --tfc-message)
      tfc_message="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

old_address=""
new_address=""
import_id=""

if [[ $auto_discover -eq 1 ]]; then
  if [[ $# -ne 0 ]]; then
    echo "Do not provide positional arguments with --auto-discover" >&2
    usage >&2
    exit 1
  fi
else
  if [[ $# -lt 2 || $# -gt 3 ]]; then
    usage >&2
    exit 1
  fi
  old_address="$1"
  new_address="$2"
  if [[ $# -eq 3 ]]; then
    import_id="$3"
  fi
fi

if command -v terraform >/dev/null 2>&1; then
  terraform_available=1
fi

if [[ $use_tfctl -eq 1 ]]; then
  if ! command -v tfctl >/dev/null 2>&1; then
    echo "tfctl is required with --use-tfctl but was not found in PATH" >&2
    echo "Install it from https://github.com/hashicorp/tfctl-cli (e.g. brew install hashicorp/tap/tfctl)." >&2
    exit 1
  fi
elif [[ $terraform_available -eq 0 ]]; then
  echo "terraform is required but was not found in PATH" >&2
  echo "Install terraform, or pass --use-tfctl to verify against HCP Terraform / Terraform Enterprise with tfctl." >&2
  exit 1
fi

if ! command -v awk >/dev/null 2>&1; then
  echo "awk is required but was not found in PATH" >&2
  exit 1
fi

run_cmd() {
  if [[ $dry_run -eq 1 ]]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

# Run tfctl with the resolved organization/hostname context, honoring --dry-run.
run_tfctl() {
  if [[ $dry_run -eq 1 ]]; then
    {
      printf '[dry-run]'
      printf ' %q' tfctl "$@"
      printf '\n'
    } >&2
    return 0
  fi
  (
    [[ -n "${tfctl_ctx_org:-}" ]] && export TFCTL_ORGANIZATION="$tfctl_ctx_org"
    [[ -n "${tfctl_ctx_host:-}" ]] && export TFCTL_HOSTNAME="$tfctl_ctx_host"
    tfctl "$@"
  )
}

# Return success when the given Terraform version can use removed/import blocks.
# import blocks need >= 1.5; removed blocks need >= 1.7. Unknown versions pass.
tf_version_supports_removed() {
  local v="$1"
  v="${v#v}"
  local major="${v%%.*}"
  local rest="${v#*.}"
  local minor="${rest%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] || return 0
  [[ "$minor" =~ ^[0-9]+$ ]] || return 0
  if (( major > 1 )); then
    return 0
  fi
  if (( major == 1 && minor >= 7 )); then
    return 0
  fi
  return 1
}

# Detect an HCP Terraform / Terraform Enterprise integration (cloud {} or
# remote backend) and capture organization, hostname, and workspace name.
detect_cloud_backend() {
  local parsed
  parsed="$(find . -type f -name '*.tf' -print0 2>/dev/null | xargs -0 awk '
    BEGIN { depth = 0; in_block = 0; block_depth = -1; in_ws = 0; ws_depth = -1; org = ""; host = ""; ws = "" }
    function opens(s, i, c, n) { n = 0; for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == "{") n++ } return n }
    function closes(s, i, c, n) { n = 0; for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == "}") n++ } return n }
    function unquote(s) { sub(/^[^"]*"/, "", s); sub(/".*$/, "", s); return s }
    {
      line = $0
      if (in_block == 0 && (line ~ /^[[:space:]]*cloud[[:space:]]*{[[:space:]]*$/ || line ~ /^[[:space:]]*backend[[:space:]]+"remote"[[:space:]]*{[[:space:]]*$/)) {
        in_block = 1
        block_depth = depth + 1
      }
      if (in_block == 1) {
        if (line ~ /^[[:space:]]*organization[[:space:]]*=[[:space:]]*"[^"]+"/) { org = unquote(line) }
        if (line ~ /^[[:space:]]*hostname[[:space:]]*=[[:space:]]*"[^"]+"/) { host = unquote(line) }
        if (in_ws == 0 && line ~ /^[[:space:]]*workspaces[[:space:]]*{[[:space:]]*$/) { in_ws = 1; ws_depth = depth + 1 }
        if (in_ws == 1 && line ~ /^[[:space:]]*name[[:space:]]*=[[:space:]]*"[^"]+"/) { ws = unquote(line) }
        if (ws == "" && line ~ /workspaces[[:space:]]*{[^}]*name[[:space:]]*=[[:space:]]*"[^"]+"/) {
          x = line
          sub(/^.*name[[:space:]]*=[[:space:]]*"/, "", x)
          sub(/".*$/, "", x)
          ws = x
        }
      }
      depth += opens(line) - closes(line)
      if (in_ws == 1 && depth < ws_depth) { in_ws = 0; ws_depth = -1 }
      if (in_block == 1 && depth < block_depth) { in_block = 0; block_depth = -1 }
    }
    END { if (org != "" || host != "" || ws != "") print org "|" host "|" ws }
  ' 2>/dev/null | head -n 1)"

  if [[ -n "$parsed" ]]; then
    tfc_detected=1
    IFS='|' read -r tfc_detected_org tfc_detected_hostname tfc_detected_workspace <<< "$parsed"
  fi
}

# Verify the migration against HCP Terraform / Terraform Enterprise via tfctl.
verify_with_tfctl() {
  local ws="$1"

  echo "== HCP Terraform / Terraform Enterprise verification (tfctl) ==" >&2

  tfctl_ctx_org="${tfc_organization:-$tfc_detected_org}"
  tfctl_ctx_host="${tfc_hostname:-$tfc_detected_hostname}"

  [[ -n "$tfctl_ctx_org" ]] && echo "Organization: ${tfctl_ctx_org}" >&2
  [[ -n "$tfctl_ctx_host" ]] && echo "Hostname: ${tfctl_ctx_host}" >&2

  if [[ $dry_run -eq 1 ]]; then
    echo "[dry-run] Would verify authentication: tfctl auth status" >&2
  elif ! run_tfctl auth status >&2; then
    echo "tfctl is not authenticated for this host. Run 'tfctl auth login' or set TFCTL_TOKEN, then retry." >&2
    return 1
  fi

  if [[ -z "$ws" ]]; then
    echo "No workspace resolved from configuration or flags." >&2
    echo "Pass --tfc-workspace NAME (or add workspaces { name = \"...\" } to the cloud block) to enable run verification." >&2
    return 0
  fi

  echo "Workspace: ${ws}" >&2

  # Warn when the workspace Terraform version cannot use removed/import blocks.
  if [[ $dry_run -eq 0 && -n "$tfctl_ctx_org" ]]; then
    local ws_tf_version=""
    ws_tf_version="$(
      [[ -n "$tfctl_ctx_org" ]] && export TFCTL_ORGANIZATION="$tfctl_ctx_org"
      [[ -n "$tfctl_ctx_host" ]] && export TFCTL_HOSTNAME="$tfctl_ctx_host"
      tfctl api "/organizations/{organization}/workspaces/${ws}" --jq '.data.attributes."terraform-version"' 2>/dev/null
    )" || ws_tf_version=""
    if [[ -n "$ws_tf_version" ]]; then
      echo "Workspace Terraform version: ${ws_tf_version}" >&2
      if ! tf_version_supports_removed "$ws_tf_version"; then
        echo "Warning: import blocks require Terraform >= 1.5 and removed blocks require >= 1.7." >&2
        echo "Update the workspace Terraform version before applying this migration." >&2
      fi
    fi
  fi

  # Optionally start a run, then always report the latest run status.
  if [[ $tfc_start_run -eq 1 ]]; then
    local msg="${tfc_message:-Kubernetes versioned-resource migration}"
    echo "Starting a run on '${ws}'. The run uses the latest configuration version in the workspace," >&2
    echo "so push your committed changes (VCS) or run a CLI plan first to upload the migrated config." >&2
    run_tfctl run start "$ws" --message="$msg" >&2 || return 1
  fi

  if [[ $dry_run -eq 1 ]]; then
    echo "[dry-run] Would check latest run: tfctl run status ${ws}" >&2
  else
    run_tfctl run status "$ws" >&2 || true
  fi

  echo "Confirm the plan in HCP Terraform shows imports only (0 to destroy) before applying." >&2
  return 0
}

is_versioned_type() {
  local resource_type="$1"
  [[ "$resource_type" =~ _v[0-9]+(alpha[0-9]+|beta[0-9]+)?$ ]]
}

load_type_map() {
  local map_path="$1"
  if [[ ! -f "$map_path" ]]; then
    return
  fi

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    local line="$raw_line"
    line="${line%%#*}"
    line="$(echo "$line" | awk '{$1=$1};1')"
    [[ -z "$line" ]] && continue
    [[ "$line" != *"="* ]] && continue
    local old_type="${line%%=*}"
    local new_type="${line#*=}"
    old_type="$(echo "$old_type" | awk '{$1=$1};1')"
    new_type="$(echo "$new_type" | awk '{$1=$1};1')"
    [[ -z "$old_type" || -z "$new_type" ]] && continue
    type_map["$old_type"]="$new_type"
  done < "$map_path"
}

infer_old_type_from_new() {
  local new_type="$1"
  local old_type=""
  local k

  for k in "${!type_map[@]}"; do
    if [[ "${type_map[$k]}" == "$new_type" ]]; then
      old_type="$k"
      break
    fi
  done

  if [[ -n "$old_type" ]]; then
    printf '%s\n' "$old_type"
    return
  fi

  old_type="$(echo "$new_type" | sed -E 's/_v[0-9]+(alpha[0-9]+|beta[0-9]+)?$//')"
  printf '%s\n' "$old_type"
}

load_address_map() {
  local map_path="$1"
  if [[ ! -f "$map_path" ]]; then
    return
  fi

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    local line="$raw_line"
    line="${line%%#*}"
    line="$(echo "$line" | awk '{$1=$1};1')"
    [[ -z "$line" ]] && continue
    [[ "$line" != *"="* ]] && continue
    local old_addr="${line%%=*}"
    local new_addr="${line#*=}"
    old_addr="$(echo "$old_addr" | awk '{$1=$1};1')"
    new_addr="$(echo "$new_addr" | awk '{$1=$1};1')"
    [[ -z "$old_addr" || -z "$new_addr" ]] && continue
    address_map["$old_addr"]="$new_addr"
  done < "$map_path"
}

infer_new_type() {
  local old_type="$1"
  if [[ -n "${type_map[$old_type]:-}" ]]; then
    printf '%s\n' "${type_map[$old_type]}"
    return
  fi
  printf '%s\n' "${old_type}_v1"
}

is_constraint_below_v3() {
  local raw_constraint="$1"
  local normalized
  local re
  normalized="$(echo "$raw_constraint" | tr -d '[:space:]')"

  re='^~>[012](\.|$)'
  if [[ "$normalized" =~ $re ]]; then
    return 0
  fi
  re='^<=?[012](\.|$)'
  if [[ "$normalized" =~ $re ]]; then
    return 0
  fi
  re='^=[012](\.|$)'
  if [[ "$normalized" =~ $re ]]; then
    return 0
  fi
  re='^<3(\.0+)?$'
  if [[ "$normalized" =~ $re ]]; then
    return 0
  fi

  if [[ "$normalized" == *"<3"* || "$normalized" == *"<3."* ]]; then
    if [[ "$normalized" != *">=3"* && "$normalized" != *">3"* ]]; then
      return 0
    fi
  fi

  return 1
}

ensure_kubernetes_provider_v3() {
  mapfile -t tf_files < <(find . -type f -name "*.tf" | sort)
  if [[ ${#tf_files[@]} -eq 0 ]]; then
    return
  fi

  local changed_files=0
  local f
  for f in "${tf_files[@]}"; do
    local current_constraint
    current_constraint="$(awk '
      BEGIN {
        depth = 0
        in_required = 0
        required_depth = -1
        in_kube = 0
        kube_depth = -1
      }
      function opens(s, i, c, n) { n = 0; for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == "{") n++ } return n }
      function closes(s, i, c, n) { n = 0; for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == "}") n++ } return n }
      {
        line = $0

        if (in_required == 0 && line ~ /^[[:space:]]*required_providers[[:space:]]*(=)?[[:space:]]*{[[:space:]]*$/) {
          in_required = 1
          required_depth = depth + 1
        }

        if (in_required == 1 && in_kube == 0 && line ~ /^[[:space:]]*kubernetes[[:space:]]*(=)?[[:space:]]*{[[:space:]]*$/) {
          in_kube = 1
          kube_depth = depth + 1
        }

        if (in_kube == 1 && line ~ /^[[:space:]]*version[[:space:]]*=[[:space:]]*"[^"]+"[[:space:]]*$/) {
          constraint = line
          sub(/^[[:space:]]*version[[:space:]]*=[[:space:]]*"/, "", constraint)
          sub(/"[[:space:]]*$/, "", constraint)
          print constraint
          exit
        }

        depth += opens(line) - closes(line)

        if (in_kube == 1 && depth < kube_depth) {
          in_kube = 0
          kube_depth = -1
        }
        if (in_required == 1 && depth < required_depth) {
          in_required = 0
          required_depth = -1
        }
      }
    ' "$f")"

    if [[ -z "$current_constraint" ]]; then
      continue
    fi
    if ! is_constraint_below_v3 "$current_constraint"; then
      continue
    fi

    local tmp
    tmp="$(mktemp)"

    awk '
      BEGIN {
        depth = 0
        in_required = 0
        required_depth = -1
        in_kube = 0
        kube_depth = -1
      }
      function opens(s, i, c, n) { n = 0; for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == "{") n++ } return n }
      function closes(s, i, c, n) { n = 0; for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == "}") n++ } return n }
      {
        line = $0

        if (in_required == 0 && line ~ /^[[:space:]]*required_providers[[:space:]]*(=)?[[:space:]]*{[[:space:]]*$/) {
          in_required = 1
          required_depth = depth + 1
        }

        if (in_required == 1 && in_kube == 0 && line ~ /^[[:space:]]*kubernetes[[:space:]]*(=)?[[:space:]]*{[[:space:]]*$/) {
          in_kube = 1
          kube_depth = depth + 1
        }

        if (in_kube == 1 && line ~ /^[[:space:]]*version[[:space:]]*=.*$/) {
          if (match(line, /^[[:space:]]*/)) {
            indent = substr(line, RSTART, RLENGTH)
          } else {
            indent = ""
          }
          print indent "version = \"~> 3.0\""
        } else {
          print line
        }

        depth += opens(line) - closes(line)

        if (in_kube == 1 && depth < kube_depth) {
          in_kube = 0
          kube_depth = -1
        }
        if (in_required == 1 && depth < required_depth) {
          in_required = 0
          required_depth = -1
        }
      }
    ' "$f" > "$tmp"

    if cmp -s "$f" "$tmp"; then
      rm -f "$tmp"
      continue
    fi

    changed_files=$((changed_files + 1))
    provider_version_bumped=1
    if [[ $dry_run -eq 1 ]]; then
      echo "[dry-run] Would update kubernetes provider version in ${f} (current: ${current_constraint}, new: ~> 3.0)" >&2
      rm -f "$tmp"
    else
      mv "$tmp" "$f"
      echo "Updated kubernetes provider version in ${f}: ${current_constraint} -> ~> 3.0" >&2
    fi
  done

  if [[ $changed_files -eq 0 ]]; then
    echo "Kubernetes provider version preflight: no changes needed" >&2
  fi
}

rewrite_unversioned_kubernetes_resources() {
  mapfile -t tf_files < <(find . -type f -name "*.tf" | sort)
  if [[ ${#tf_files[@]} -eq 0 ]]; then
    return
  fi

  local resource_decl_re
  resource_decl_re='^([[:space:]]*resource[[:space:]]+")([^"]+)("[[:space:]]+"[^"]+"[[:space:]]*\{[[:space:]]*)$'

  local rewritten_count=0
  local f
  for f in "${tf_files[@]}"; do
    local tmp
    tmp="$(mktemp)"
    local changed_file=0

    while IFS= read -r line || [[ -n "$line" ]]; do
      local out_line="$line"
      if [[ "$line" =~ $resource_decl_re ]]; then
        local resource_type="${BASH_REMATCH[2]}"
        local decl_prefix="${BASH_REMATCH[1]}"
        local decl_suffix="${BASH_REMATCH[3]}"
        if [[ "$resource_type" == kubernetes_* ]] && ! is_versioned_type "$resource_type"; then
          local new_type
          new_type="$(infer_new_type "$resource_type")"
          if [[ "$new_type" != "$resource_type" ]]; then
            out_line="${decl_prefix}${new_type}${decl_suffix}"
            changed_file=1
            rewritten_count=$((rewritten_count + 1))
            if [[ $dry_run -eq 1 ]]; then
              echo "[dry-run] Would rewrite resource type in ${f}: ${resource_type} -> ${new_type}" >&2
            else
              echo "Rewrote resource type in ${f}: ${resource_type} -> ${new_type}" >&2
            fi
          fi
        fi
      fi
      printf '%s\n' "$out_line" >> "$tmp"
    done < "$f"

    if [[ $changed_file -eq 1 ]]; then
      config_rewritten=1
      if [[ $dry_run -eq 0 ]]; then
        mv "$tmp" "$f"
      else
        rm -f "$tmp"
      fi
    else
      rm -f "$tmp"
    fi
  done

  if [[ $rewritten_count -eq 0 ]]; then
    echo "Kubernetes resource rewrite preflight: no changes needed" >&2
  fi
}

discover_config_addresses() {
  find . -type f -name "*.tf" -print0 |
    xargs -0 awk '
      $1 == "resource" {
        type = $2
        name = $3
        gsub(/"/, "", type)
        gsub(/"/, "", name)
        if (type ~ /^kubernetes_/) {
          print type "." name
        }
      }
    ' 2>/dev/null | sort -u
}

infer_resource_id_from_config() {
  local file_path="$1"
  local resource_type="$2"
  local resource_name="$3"

  awk -v rt="$resource_type" -v rn="$resource_name" '
    BEGIN {
      depth = 0
      in_resource = 0
      resource_depth = -1
      in_metadata = 0
      metadata_depth = -1
      name = ""
      namespace = ""
    }
    function opens(s, i, c, n) { n = 0; for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == "{") n++ } return n }
    function closes(s, i, c, n) { n = 0; for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == "}") n++ } return n }
    {
      line = $0
      if (in_resource == 0 && line ~ /^[[:space:]]*resource[[:space:]]+"[^"]+"[[:space:]]+"[^"]+"[[:space:]]*{[[:space:]]*$/) {
        tmp = line
        sub(/^[[:space:]]*resource[[:space:]]+"/, "", tmp)
        split(tmp, p1, "\"")
        type = p1[1]
        rest = substr(tmp, length(type) + 2)
        sub(/^[[:space:]]*"/, "", rest)
        split(rest, p2, "\"")
        rname = p2[1]
        if (type == rt && rname == rn) {
          in_resource = 1
          resource_depth = depth + 1
        }
      }

      if (in_resource == 1 && in_metadata == 0 && line ~ /^[[:space:]]*metadata[[:space:]]*{[[:space:]]*$/) {
        in_metadata = 1
        metadata_depth = depth + 1
      }

      if (in_metadata == 1 && line ~ /^[[:space:]]*name[[:space:]]*=[[:space:]]*"[^"]+"[[:space:]]*$/) {
        x = line
        sub(/^[[:space:]]*name[[:space:]]*=[[:space:]]*"/, "", x)
        sub(/"[[:space:]]*$/, "", x)
        name = x
      }
      if (in_metadata == 1 && line ~ /^[[:space:]]*namespace[[:space:]]*=[[:space:]]*"[^"]+"[[:space:]]*$/) {
        x = line
        sub(/^[[:space:]]*namespace[[:space:]]*=[[:space:]]*"/, "", x)
        sub(/"[[:space:]]*$/, "", x)
        namespace = x
      }

      depth += opens(line) - closes(line)

      if (in_metadata == 1 && depth < metadata_depth) {
        in_metadata = 0
        metadata_depth = -1
      }
      if (in_resource == 1 && depth < resource_depth) {
        if (name != "" && namespace != "") {
          print namespace "/" name
        } else if (name != "") {
          print name
        }
        exit
      }
    }
  ' "$file_path" | head -n 1
}

record_candidate() {
  local file_path="$1"
  local old_addr="$2"
  local new_addr="$3"
  local import_id_value="$4"
  printf '%s\t%s\t%s\t%s\n' "$file_path" "$old_addr" "$new_addr" "$import_id_value" >> "$candidates_file"
}

has_existing_migration_blocks() {
  local old_addr="$1"
  local new_addr="$2"
  if grep -R --include='*.tf' -Fq "from = ${old_addr}" . && grep -R --include='*.tf' -Fq "to = ${new_addr}" .; then
    return 0
  fi
  return 1
}

append_migration_blocks() {
  local file_path="$1"
  local old_addr="$2"
  local new_addr="$3"
  local import_id_value="$4"

  if has_existing_migration_blocks "$old_addr" "$new_addr"; then
    echo "Skipping block insertion for ${old_addr} -> ${new_addr}: matching blocks already exist" >&2
    return
  fi

  if [[ -z "$import_id_value" ]]; then
    import_id_value="<resource_id>"
  fi

  if [[ $dry_run -eq 1 ]]; then
    echo "[dry-run] Would append removed/import blocks in ${file_path}: ${old_addr} -> ${new_addr} (id: ${import_id_value})" >&2
    return
  fi

  cat >> "$file_path" <<EOF

removed {
  from = ${old_addr}
  lifecycle {
    destroy = false
  }
}

import {
  to = ${new_addr}
  id = "${import_id_value}"
}
EOF
  echo "Added removed/import blocks in ${file_path}: ${old_addr} -> ${new_addr}" >&2
}

pushd "$terraform_dir" >/dev/null

candidates_file="$(mktemp)"

if [[ $skip_provider_version_bump -eq 0 ]]; then
  ensure_kubernetes_provider_v3
fi

load_address_map "$address_map_file"
load_type_map "$type_map_file"

if [[ $skip_config_rewrite -eq 0 ]]; then
  rewrite_unversioned_kubernetes_resources
fi

if [[ $provider_version_bumped -eq 1 ]]; then
  if [[ $terraform_available -eq 0 ]]; then
    echo "Skipping terraform init -upgrade: terraform not found in PATH (the remote run will refresh provider selections)." >&2
  elif [[ $dry_run -eq 1 ]]; then
    echo "[dry-run] Would run terraform init -upgrade to refresh provider lock selections" >&2
  else
    echo "Running terraform init -upgrade to refresh provider lock selections" >&2
    terraform init -upgrade
  fi
fi

echo "Terraform directory: $(pwd)" >&2

if [[ $auto_discover -eq 0 ]]; then
  echo "Preparing migration blocks: ${old_address} -> ${new_address}" >&2
fi

if [[ $auto_discover -eq 1 ]]; then
  migrations_found=0
  mapfile -t config_addresses < <(discover_config_addresses)
  declare -A config_set
  for addr in "${config_addresses[@]}"; do
    config_set["$addr"]=1
  done

  mapfile -t tf_files < <(find . -type f -name "*.tf" | sort)
  for tf in "${tf_files[@]}"; do
    while IFS=$'\t' read -r resource_type resource_name; do
      [[ -z "$resource_type" || -z "$resource_name" ]] && continue
      old_type="$(infer_old_type_from_new "$resource_type")"
      old_addr="${old_type}.${resource_name}"
      new_addr="${resource_type}.${resource_name}"

      if [[ "$old_addr" == "$new_addr" ]]; then
        continue
      fi

      inferred_id="$(infer_resource_id_from_config "$tf" "$resource_type" "$resource_name")"
      migrations_found=$((migrations_found + 1))
      echo "Discovered (config): ${old_addr} -> ${new_addr} (id: ${inferred_id:-<resource_id>})" >&2
      record_candidate "$tf" "$old_addr" "$new_addr" "$inferred_id"
    done < <(awk '
      $1 == "resource" {
        type = $2
        name = $3
        gsub(/"/, "", type)
        gsub(/"/, "", name)
        if (type ~ /^kubernetes_/ && type ~ /_v[0-9]+(alpha[0-9]+|beta[0-9]+)?$/) {
          print type "\t" name
        }
      }
    ' "$tf")
  done

  for mapped_old in "${!address_map[@]}"; do
    mapped_new="${address_map[$mapped_old]}"
    if grep -R --include='*.tf' -Fq "resource \"${mapped_new%%.*}\" \"${mapped_new##*.}\"" .; then
      migrations_found=$((migrations_found + 1))
      echo "Discovered (address-map): ${mapped_old} -> ${mapped_new} (id: <resource_id>)" >&2
      record_candidate "./main.tf" "$mapped_old" "$mapped_new" ""
    fi
  done

  if [[ $migrations_found -eq 0 ]]; then
    echo "No kubernetes migration blocks to add" >&2
  fi

  if [[ $discover_only -eq 1 ]]; then
    echo "Discovery only mode complete. Found ${migrations_found} candidate(s)." >&2
    rm -f "$candidates_file"
    popd >/dev/null
    exit 0
  fi

  while IFS=$'\t' read -r target_file old_addr new_addr block_id; do
    [[ -z "$target_file" ]] && continue
    append_migration_blocks "$target_file" "$old_addr" "$new_addr" "$block_id"
  done < "$candidates_file"
else
  if [[ -z "$import_id" ]]; then
    import_id="<resource_id>"
  fi

  append_migration_blocks "./main.tf" "$old_address" "$new_address" "$import_id"
fi

detect_cloud_backend
if [[ $tfc_detected -eq 1 ]]; then
  echo "Detected HCP Terraform / Terraform Enterprise integration (cloud or remote backend)." >&2
  echo "State lives in the remote workspace; this config-based migration leaves it untouched." >&2
fi

if [[ $skip_plan -eq 1 ]]; then
  :
elif [[ $use_tfctl -eq 1 ]]; then
  verify_with_tfctl "${tfc_workspace:-$tfc_detected_workspace}" || \
    echo "tfctl verification reported an issue (see messages above). The configuration changes are still in place." >&2
  if [[ $terraform_available -eq 1 && $tfc_detected -eq 1 ]]; then
    echo "Running terraform plan (remote speculative plan of the migrated configuration)." >&2
    run_cmd terraform plan -no-color || true
  fi
elif [[ $terraform_available -eq 1 ]]; then
  run_cmd terraform plan -no-color
else
  echo "Skipping verification: terraform not found and --use-tfctl not set." >&2
fi

rm -f "$candidates_file"
popd >/dev/null
