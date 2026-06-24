# Resource name mappings

Old-to-new type mappings come from the full v3 deprecation table in
[../scripts/kubernetes-versioned-type-map.txt](../scripts/kubernetes-versioned-type-map.txt).
The script falls back to appending `_v1` for any type not listed.

Two special cases:

- `kubernetes_horizontal_pod_autoscaler` maps to `_v1` or `_v2` (the map
  defaults to `_v2`).
- `kubernetes_pod_security_policy` is removed upstream; there is no replacement.

## Custom address overrides

For renamed local names or module-scoped addresses, add explicit
`old_address=new_address` overrides in
[../scripts/kubernetes-versioned-address-map.txt](../scripts/kubernetes-versioned-address-map.txt).
This file is optional and only needed when type-based inference is insufficient.
