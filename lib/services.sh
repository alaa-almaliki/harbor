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
  defaults="${3-}"
  # Distinguish "no third argument" (framework default applies — cmd_init's
  # two-arg call) from "third argument is the empty string" (a DB-less
  # project's actual current list — cmd_services' three-arg call). Testing
  # emptiness alone conflates the two: a project with NO services would fall
  # through here to the framework default, preselecting a database it doesn't
  # have and turning a bare Enter into "silently add mysql" — the inverse of
  # what this argument exists to prevent.
  if [ "$#" -lt 3 ]; then defaults="$(_init_services "$framework" | tr -s ', ' ' ')"; fi
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

# _services_at_risk <name> <old> <new> — pure risk assessment for
# services_confirm_shrink, split out as a testability seam (CLAUDE.md §6.5):
# it returns the "svc:vol" pairs at risk without touching stdin/confirm, so
# tests can assert the determination without stubbing an interactive prompt.
#
# Three-way outcome per dropped service's volume:
#   1. `docker volume inspect` succeeds        -> volume exists    -> at risk
#   2. it fails AND the error clearly means the volume is absent   -> not at risk
#   3. it fails for any other reason (unreachable daemon, permission
#      error, wrong DOCKER_HOST/context, transient fault, ...)     -> unknown,
#      assume at risk
# Docker doesn't give a distinct exit code for "no such volume" vs. other
# failures, so outcome 2 is decided by matching the error text
# case-insensitively and defensively: if it doesn't clearly say the volume is
# absent, fall into outcome 3. When in doubt, prompt — a spurious prompt is a
# mild annoyance, a skipped one silently loses someone's database access.
_services_at_risk() {
  local name="$1" old="$2" new="$3" svc vol err atrisk="" dockerup=1
  # If we can't reach Docker at all we can't tell whether data exists. Assume
  # it does and prompt anyway: skipping the prompt because the daemon happens
  # to be down turns a safety gate into a coin flip, and "no prompt appeared"
  # is exactly how a user concludes nothing was at stake.
  docker info >/dev/null 2>&1 || dockerup=0
  for svc in $(services_dropped "$old" "$new"); do
    vol="$(_service_volume "$name" "$svc")"
    [ -n "$vol" ] || continue
    if [ "$dockerup" = 0 ]; then
      atrisk="$atrisk $svc:$vol"
      continue
    fi
    if err="$(docker volume inspect "$vol" 2>&1 >/dev/null)"; then
      atrisk="$atrisk $svc:$vol"
    else
      case "$(printf '%s' "$err" | tr '[:upper:]' '[:lower:]')" in
        *"no such volume"*) ;;                 # confirmed absent — not at risk
        *) atrisk="$atrisk $svc:$vol" ;;       # unknown failure — assume at risk
      esac
    fi
  done
  printf '%s' "$atrisk"
}

# services_confirm_shrink <name> <old> <new> — confirm before dropping a service
# whose data volume still exists. Removing a service does NOT delete data: the
# named volume is left in place and re-adding the service reattaches it intact;
# only `harbor destroy` drops volumes. Say so — an alarmist prompt for a
# reversible action trains people to ignore the prompts that aren't.
services_confirm_shrink() {
  local name="$1" old="$2" new="$3" atrisk pair
  atrisk="$(_services_at_risk "$name" "$old" "$new")"
  [ -n "$atrisk" ] || return 0
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

# services_apply <old-list> <add|rm> <svc>... — pure list algebra. Adding a
# present service and removing an absent one are both no-ops (idempotence).
services_apply() {
  local old="$1" op="$2"; shift 2
  local svc out=""
  case "$op" in
    add)
      out="$old"
      for svc in "$@"; do
        case " $out " in *" $svc "*) continue ;; esac
        if [ -z "$out" ]; then out="$svc"; else out="$out $svc"; fi
      done ;;
    rm)
      for svc in $old; do
        case " $* " in *" $svc "*) continue ;; esac
        if [ -z "$out" ]; then out="$svc"; else out="$out $svc"; fi
      done ;;
  esac
  printf '%s' "$out"
}

# harbor services [list|add|rm] <name> [svc...] — inspect or change a project's
# backing services. Writes the manifest, then re-renders. Deliberately does NOT
# run `up`: rendering is idempotent, restarting containers is not, and a user
# may be making several changes in a row.
cmd_services() {
  local sub="${1-}" name svc catalog cur new
  case "$sub" in
    list|add|rm) shift ;;
    "")          usage_die services "harbor services <name> | list|add|rm <name> [svc...]" ;;
    *)           sub="" ;;   # `harbor services <name>` -> the picker
  esac
  require_name "${1-}"; name="$1"; shift || true
  local mf; mf="$(manifest_path "$name")"
  [ -f "$mf" ] || die "not initialized: $name → harbor init $name"
  local framework; framework="$(manifest_get "$mf" framework "")"
  catalog="$(services_catalog)"
  cur="$(_project_services "$name" "$framework")"

  case "$sub" in
    list)
      [ "$#" -eq 0 ] || usage_die services "harbor services list $name"
      printf 'Services for %s  (catalog: %s)\n' "'$name'" "$catalog"
      for svc in $catalog; do
        case " $cur " in
          *" $svc "*) printf '  [x] %-14s %s\n' "$svc" "$(_service_image "$name" "$svc")" ;;
          *)          printf '  [ ] %s\n' "$svc" ;;
        esac
      done
      return 0 ;;
    add|rm)
      [ "$#" -gt 0 ] || usage_die services "harbor services $sub $name <svc>..."
      services_validate "$@"
      new="$(services_apply "$cur" "$sub" "$@")" ;;
    *)
      new="$(services_select "$name" "$framework" "$cur")" ;;
  esac

  if [ "$new" = "$cur" ]; then ok "no change: $name services unchanged ($cur)"; return 0; fi

  # Pre-flight the one precondition cmd_render's call graph would `die` on
  # (ports_ensure — lib/init.sh) BEFORE the manifest is touched below. A `die`
  # calls `exit`, which terminates the process outright — including the
  # restore a few lines down — regardless of whether cmd_render otherwise
  # returns cleanly. Reproduced: delete var/ports/<name>, then `harbor services
  # add <name> <svc>`; without this preflight the manifest was rewritten to
  # include the new service and the process died on "ports not allocated"
  # before ever reaching the restore, leaving the half-applied manifest as the
  # user's only trace. ports_ensure is a cheap, idempotent, lock-guarded
  # backfill (CLAUDE.md §1.7) — running it again inside cmd_render right after
  # this is harmless.
  ports_ensure "$name" || die "ports not allocated for $name → harbor init $name"

  # Write, then render — and RESTORE the manifest if the render's confirm gate is
  # declined. Without the restore, answering "n" would leave the manifest already
  # rewritten while nothing else was applied: the exact "decline still mutates
  # state" defect fixed in Task 7, reintroduced one layer up. Capture the raw
  # line rather than rebuilding it, so a decline is byte-for-byte a no-op.
  local prev had_prev=0; prev="$(manifest_get "$mf" services "")"
  manifest_has "$mf" services && had_prev=1
  # shellcheck disable=SC2086  # word-split the resolved service list
  manifest_set_line "$mf" services "{ $(_services_map_body "$name" $new) }"
  if ! cmd_render "$name"; then       # carries the shrink-confirm gate from Task 7
    if [ "$had_prev" = 1 ]; then
      manifest_set_line "$mf" services "$prev"
    else
      # The key never existed before (legacy manifest). Restoring with
      # manifest_set_line would leave a bare "services:" line — present but
      # empty is not the same file as the key being absent, even though
      # manifest_get can't tell the two apart on read. Remove the line so a
      # decline is byte-for-byte a no-op.
      manifest_del_line "$mf" services
    fi
    warn "reverted: $name services unchanged"
    return 1
  fi
}
