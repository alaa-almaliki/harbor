#!/usr/bin/env bash
# toolbox.sh — containerized CLI tools. Declare in manifest `tools:`; Harbor
# generates a shim at .harbor/bin/<bin> that runs the tool in a throwaway
# container with the project dir + $TMPDIR mounted at identical paths. No host
# installs; nothing outside the project.

# built-in name -> "image|bin" catalog (override via manifest tools.<name>.image)
_tool_catalog() {
  case "$1" in
    wkhtmltopdf) echo "surnet/alpine-wkhtmltopdf:3.0.1-0.12.6-full|wkhtmltopdf" ;;
    ghostscript|gs) echo "minidocks/ghostscript|gs" ;;
    pandoc) echo "pandoc/core|pandoc" ;;
    ffmpeg) echo "linuxserver/ffmpeg|ffmpeg" ;;
    soffice|libreoffice) echo "linuxserver/libreoffice|soffice" ;;
    *) echo "" ;;
  esac
}

_tool_spec() {
  local name="$1" tool="$2" mf img bin
  mf="$(manifest_path "$name")"
  img="$(manifest_get "$mf" "tools.$tool.image" "")"
  if [ -n "$img" ]; then
    bin="$(manifest_get "$mf" "tools.$tool.bin" "$tool")"
    printf '%s|%s' "$img" "$bin"; return 0
  fi
  _tool_catalog "$tool"
}

tools_declared() {
  local mf="$1" raw; raw="$(manifest_get "$mf" tools "")"
  [ -n "$raw" ] || return 0
  case "$raw" in
    \[*) manifest_list "$mf" tools ;;
    \{*) manifest_map_keys "$mf" tools ;;
    *) : ;;
  esac
}

tool_write_shim() {
  local name="$1" tool="$2" spec img bin dir shim
  spec="$(_tool_spec "$name" "$tool")"
  [ -n "$spec" ] || die "unknown tool '$tool' — add to manifest: tools: { $tool: { image: <img>, bin: <bin> } }"
  img="${spec%|*}"; bin="${spec#*|}"
  dir="$(project_dir "$name")"
  shim="$dir/.harbor/bin/$bin"
  mkdir -p "$dir/.harbor/bin"
  cat > "$shim" <<EOF
#!/usr/bin/env bash
# Harbor containerized tool: $tool -> $img (generated). Host stays clean.
exec docker run --rm -i \\
  -v "$dir:$dir" \\
  -v "\${TMPDIR:-/tmp}:\${TMPDIR:-/tmp}" \\
  -w "\$PWD" \\
  "$img" $bin "\$@"
EOF
  chmod +x "$shim"
  printf '%s' "$shim"
}

cmd_tools() {
  [ "${1-}" = "sync" ] || die "usage: harbor tools sync <name>"
  shift; require_name "${1-}"; local name="$1" mf t n=0
  mf="$(manifest_path "$name")"
  for t in $(tools_declared "$mf"); do
    tool_write_shim "$name" "$t" >/dev/null; step "shim: $t"; n=$((n + 1))
  done
  ok "synced $n tool shim(s) -> $(project_harbor_dir "$name")/bin/"
}

cmd_tool() {
  require_name "${1-}"; local name="$1" tool="${2-}"
  [ -n "$tool" ] || die "usage: harbor tool <name> <tool> [args...]"
  shift 2
  docker info >/dev/null 2>&1 || die "docker daemon not running"
  local dir shim; dir="$(project_dir "$name")"
  shim="$(tool_write_shim "$name" "$tool")"
  ( cd "$dir" && exec "$shim" "$@" )
}
