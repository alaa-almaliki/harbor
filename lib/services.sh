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

# services_pick_parse <input> <catalog> <defaults> — pure picker-input parser.
# "" -> defaults, "none" -> empty, otherwise 1-based indexes into <catalog>
# (space- or comma-separated). Prints __INVALID__ on anything else, so the
# caller can re-prompt. Output order follows the catalog, not the input.
services_pick_parse() {
  local input="$1" catalog="$2" defaults="$3" tok i n svc out=""
  # Normalize first: commas -> spaces, runs of whitespace squeezed, ends trimmed.
  # This must NOT delete inner whitespace ("1 3" is two tokens, not "13").
  #
  # The trim matters for correctness, not tidiness: a bare Enter and a
  # space-then-Enter must both mean "defaults". Without it, whitespace-only
  # input falls through to the index loop, matches nothing, and returns "" —
  # silently choosing NO SERVICES from what the user experienced as pressing
  # Enter. Same failure shape as a bare `--services` with no value.
  input="$(printf '%s' "$input" | tr ',' ' ' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
  case "$input" in
    "")     printf '%s' "$defaults"; return 0 ;;
    none)   printf ''; return 0 ;;
  esac
  # collect chosen indexes, validating each token is a digit in range
  local chosen=" "
  n=0; for svc in $catalog; do n=$((n + 1)); done
  for tok in $input; do          # already comma-free and squeezed
    case "$tok" in
      ''|*[!0-9]*) printf '__INVALID__'; return 0 ;;
    esac
    if [ "$tok" -lt 1 ] || [ "$tok" -gt "$n" ]; then printf '__INVALID__'; return 0; fi
    chosen="$chosen$tok "
  done
  i=0
  for svc in $catalog; do
    i=$((i + 1))
    case "$chosen" in
      *" $i "*) if [ -z "$out" ]; then out="$svc"; else out="$out $svc"; fi ;;
    esac
  done
  printf '%s' "$out"
}

# services_select <name> <framework> — the resolved service list for a new
# project. Prompts only when Harbor is genuinely interactive; a non-TTY caller
# (scripts, CI) and HARBOR_YES=1 both get the framework default silently, so no
# existing scripted `harbor init` changes behavior.
services_select() {
  local name="$1" framework="$2" catalog defaults reply parsed i svc mark
  catalog="$(services_catalog)"
  defaults="$(_init_services "$framework" | tr -s ', ' ' ')"
  if [ ! -t 0 ] || [ "${HARBOR_YES:-0}" = "1" ]; then
    printf '%s' "$defaults"; return 0
  fi
  printf '\nServices for %s  (framework: %s)\n' "'$name'" "$framework" >&2
  i=0
  for svc in $catalog; do
    i=$((i + 1)); mark=""
    case " $defaults " in *" $svc "*) mark="  *default" ;; esac
    printf '  %d) %-14s%s\n' "$i" "$svc" "$mark" >&2
  done
  while :; do
    printf 'Select [Enter = defaults · numbers e.g. "1 3" · "none"]: ' >&2
    read -r reply || { printf '%s' "$defaults"; return 0; }
    parsed="$(services_pick_parse "$reply" "$catalog" "$defaults")"
    if [ "$parsed" != "__INVALID__" ]; then printf '%s' "$parsed"; return 0; fi
    warn "not a valid selection: $reply"
  done
}

# services_dropped <old> <new> — services present in <old> but not <new>.
services_dropped() {
  local old="$1" new="$2" svc out=""
  for svc in $old; do
    case " $new " in
      *" $svc "*) ;;
      *) if [ -z "$out" ]; then out="$svc"; else out="$out $svc"; fi ;;
    esac
  done
  printf '%s' "$out"
}

# _service_volume <name> <svc> — the docker volume a service's data lives in, or
# empty if it has none. Volumes are named and scoped to the compose project
# (`name: harbor-<name>` in templates/compose/header.yml.tmpl).
_service_volume() {
  local name="$1" svc="$2" vol=""
  [ -f "$HARBOR_TEMPLATES/compose/volumes/$svc.yml.tmpl" ] || { printf ''; return 0; }
  vol="$(tr -d ' :' < "$HARBOR_TEMPLATES/compose/volumes/$svc.yml.tmpl" | head -1)"
  printf 'harbor-%s_%s' "$name" "$vol"
}

# services_confirm_shrink <name> <old> <new> — confirm before dropping a service
# whose data volume still exists. Removing a service does NOT delete data: the
# named volume is left in place and re-adding the service reattaches it intact;
# only `harbor destroy` drops volumes. Say so — an alarmist prompt for a
# reversible action trains people to ignore the prompts that aren't.
services_confirm_shrink() {
  local name="$1" old="$2" new="$3" svc vol atrisk="" dockerup=1
  # If we can't reach Docker we can't tell whether data exists. Assume it does
  # and prompt anyway: skipping the prompt because the daemon happens to be down
  # turns a safety gate into a coin flip, and "no prompt appeared" is exactly how
  # a user concludes nothing was at stake.
  docker info >/dev/null 2>&1 || dockerup=0
  for svc in $(services_dropped "$old" "$new"); do
    vol="$(_service_volume "$name" "$svc")"
    [ -n "$vol" ] || continue
    if [ "$dockerup" = 0 ] || docker volume inspect "$vol" >/dev/null 2>&1; then
      atrisk="$atrisk $svc:$vol"
    fi
  done
  [ -n "$atrisk" ] || return 0
  local pair
  for pair in $atrisk; do
    warn "removing ${pair%%:*} from '$name' stops its container and unmounts its data"
    step "the volume ${pair#*:} is KEPT — re-adding ${pair%%:*} reattaches it intact"
    step "only 'harbor destroy $name' drops it"
  done
  confirm "Remove$(for pair in $atrisk; do printf ' %s' "${pair%%:*}"; done) from '$name'?"
}

# project_has_service <name> <svc> — is <svc> in this project's resolved list?
# Convenience for one-off checks (doctor, wire, db). Callers that test several
# services in a row should resolve the list ONCE and `case` against it instead —
# see init_write_connection — since each call here re-parses the manifest.
project_has_service() {
  local name="$1" svc="$2" framework
  framework="$(manifest_get "$(manifest_path "$name")" framework "")"
  case " $(_project_services "$name" "$framework") " in
    *" $svc "*) return 0 ;;
    *) return 1 ;;
  esac
}
