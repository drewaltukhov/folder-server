#compdef fs folder-server
# zsh completion for folder-server. Installed to
# <brew-prefix>/share/zsh/site-functions/_fs by install.sh.

local -a _fs_cmds
_fs_cmds=(
  'setup:One-time machine setup'
  'serve:Zero-config: serve + open the browser'
  'init:Create a .folderserver config here'
  'up:Serve this folder (or --all)'
  'down:Stop this folder (or --all)'
  'restart:Restart this folder'
  'edit:Edit this folder config (php, routing, MySQL)'
  'unbind:Stop, delete config, forget the site (or --all)'
  'list:List all sites and their status'
  'open:Open this folder URL in the browser'
  'logs:Tail this folder log'
  'db:Control the shared MySQL service'
  'dash:Live TUI dashboard'
  'autostart:Start all sites at login'
  'lan:Expose this site to the local network (phones/tablets)'
  'help:Show help'
  'version:Show version'
)

if (( CURRENT == 2 )); then
  _describe -t commands 'fs command' _fs_cmds
  return
fi

case "$words[2]" in
  up|down|restart) _arguments '--all[apply to every known site]' '*:directory:_files -/' ;;
  unbind)          _arguments '--all[apply to every known site]' '*:directory:_files -/' ;;
  db)              _values 'action' start stop status ;;
  autostart)       _values 'action' on off status ;;
  lan)             _values 'action' on off status ca ;;
esac
