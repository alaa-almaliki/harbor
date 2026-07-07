#!/usr/bin/env bash
# completion.sh — emit bash/zsh completion (commands + project names).

_HARBOR_CMDS="doctor setup stop start teardown php xdebug init render link unlink wire up down restart destroy logs run composer artisan console spark magento node npm tool tools db install seed store media new open status ps list mysql redis shell secure mail completion version help"

cmd_completion() {
  case "${1-}" in
    bash) _completion_bash ;;
    zsh)  _completion_zsh ;;
    *) die "usage: harbor completion bash|zsh" ;;
  esac
}

_completion_bash() {
  cat <<EOF
# harbor bash completion — add to ~/.bashrc:  source <(harbor completion bash)
_harbor() {
  local cur prev cmds projects
  cur="\${COMP_WORDS[COMP_CWORD]}"; prev="\${COMP_WORDS[COMP_CWORD-1]}"
  cmds="$_HARBOR_CMDS"
  if [ "\$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=(\$(compgen -W "\$cmds" -- "\$cur")); return
  fi
  case "\$prev" in
    php) COMPREPLY=(\$(compgen -W "$HARBOR_PHP_VERSIONS sync use" -- "\$cur")); return ;;
    use) COMPREPLY=(\$(compgen -W "$HARBOR_PHP_VERSIONS" -- "\$cur")); return ;;
    xdebug) COMPREPLY=(\$(compgen -W "on off status" -- "\$cur")); return ;;
    logs) COMPREPLY=(\$(compgen -W "clear nginx php dnsmasq \$(ls \"$HARBOR_PROJECTS\" 2>/dev/null)" -- "\$cur")); return ;;
    db) COMPREPLY=(\$(compgen -W "create drop backup import pull sandbox" -- "\$cur")); return ;;
    sandbox) COMPREPLY=(\$(compgen -W "create drop list backup restore console up down destroy status" -- "\$cur")); return ;;
    store) COMPREPLY=(\$(compgen -W "add list rm" -- "\$cur")); return ;;
  esac
  projects=\$(ls "$HARBOR_PROJECTS" 2>/dev/null)
  COMPREPLY=(\$(compgen -W "\$projects" -- "\$cur"))
}
complete -F _harbor harbor
EOF
}

_completion_zsh() {
  cat <<EOF
# harbor zsh completion — add to ~/.zshrc:  source <(harbor completion zsh)
_harbor() {
  local -a cmds projects
  cmds=(${_HARBOR_CMDS})
  if (( CURRENT == 2 )); then compadd \$cmds; return; fi
  case "\${words[CURRENT-1]}" in
    php) compadd ${HARBOR_PHP_VERSIONS} sync use; return ;;
    use) compadd ${HARBOR_PHP_VERSIONS}; return ;;
    xdebug) compadd on off status; return ;;
    logs) compadd clear nginx php dnsmasq \$(ls "$HARBOR_PROJECTS" 2>/dev/null); return ;;
    db) compadd create drop backup import pull sandbox; return ;;
    sandbox) compadd create drop list backup restore console up down destroy status; return ;;
    store) compadd add list rm; return ;;
  esac
  projects=(\$(ls "$HARBOR_PROJECTS" 2>/dev/null))
  compadd \$projects
}
compdef _harbor harbor
EOF
}
