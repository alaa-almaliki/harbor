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

# services_parse_arg <csv> — normalize a --services value to a space-separated
# list. "" and "none" both mean no services. Validates every name.
services_parse_arg() {
  local raw="$1" svc out=""
  case "$raw" in ""|none) printf ''; return 0 ;; esac
  for svc in $(printf '%s' "$raw" | tr ',' ' '); do
    case " $out " in *" $svc "*) continue ;; esac   # dedupe
    if [ -z "$out" ]; then out="$svc"; else out="$out $svc"; fi
  done
  # shellcheck disable=SC2086  # deliberate word-split of the validated list
  services_validate $out
  printf '%s' "$out"
}

# services_select <name> <framework> — replaced by the picker in Task 4.
services_select() { _init_services "$2" | tr -s ', ' ' '; }
