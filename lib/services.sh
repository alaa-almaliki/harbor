#!/usr/bin/env bash
# services.sh — the service catalog and a project's service selection.
#
# The catalog is DERIVED from templates/compose/services/*.yml.tmpl, so adding a
# service template makes it selectable with no second list to maintain.

# services_catalog — space-separated names of every bundled service.
services_catalog() {
  local f out="" n
  for f in "$HARBOR_TEMPLATES"/compose/services/*.yml.tmpl; do
    [ -f "$f" ] || continue
    n="$(basename "$f" .yml.tmpl)"
    if [ -z "$out" ]; then out="$n"; else out="$out $n"; fi
  done
  printf '%s' "$out"
}

# services_validate <name>... — die with a fix hint on an unknown service.
services_validate() {
  local svc cat; cat="$(services_catalog)"
  for svc in "$@"; do
    case " $cat " in
      *" $svc "*) ;;
      *) die "unknown service '$svc' → one of: $cat" ;;
    esac
  done
}
