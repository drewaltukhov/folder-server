# shellcheck shell=bash disable=SC2207  # COMPREPLY=( $(compgen ...) ) is the standard idiom
# bash completion for folder-server. Installed to
# <brew-prefix>/etc/bash_completion.d/fs by install.sh.
_fs_complete() {
  local cur cmds
  cur="${COMP_WORDS[COMP_CWORD]}"
  cmds="setup serve init up down restart edit unbind list open logs db dash autostart help version"

  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
    return
  fi

  case "${COMP_WORDS[1]}" in
    up|down|restart|unbind)
      COMPREPLY=( $(compgen -W "--all" -- "$cur") $(compgen -d -- "$cur") ) ;;
    db)        COMPREPLY=( $(compgen -W "start stop status" -- "$cur") ) ;;
    autostart) COMPREPLY=( $(compgen -W "on off status" -- "$cur") ) ;;
    *)         COMPREPLY=() ;;
  esac
}
complete -F _fs_complete fs folder-server
