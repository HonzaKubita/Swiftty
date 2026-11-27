# Swiftty shell integration for zsh.
#
# Swiftty draws its own native prompt, so the shell's prompt is hidden. The
# shell reports each command's steps with OSC 133 (prompt, input, output,
# end + exit code) and its directory with OSC 7; Swiftty builds command
# blocks from those marks.

[[ -n "$_SWIFTTY_LOADED" ]] && return
typeset -g _SWIFTTY_LOADED=1
export SWIFTTY=1
export TERM_PROGRAM=Swiftty

typeset -g _swiftty_running=0

# _swiftty_report: prints the state Swiftty's plugins ask for (git branch, …).
[[ -r "$SWIFTTY_INTEGRATION_DIR/report.sh" ]] && source "$SWIFTTY_INTEGRATION_DIR/report.sh"

_swiftty_urlencode() {
  emulate -L zsh
  local LC_ALL=C s="$1" out="" c i
  for (( i = 1; i <= ${#s}; i++ )); do
    c="${s[i]}"
    case "$c" in
      [a-zA-Z0-9.~_/-]) out+="$c" ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  print -rn -- "$out"
}

_swiftty_precmd() {
  local ret=$?
  if (( _swiftty_running )); then
    print -n "\e]133;D;${ret}\a"
    _swiftty_running=0
    # A blank line between command blocks.
    print
  fi
  print -n "\e]7;file://${HOST}$(_swiftty_urlencode "$PWD")\a"
  (( $+functions[_swiftty_report] )) && _swiftty_report
  # Hide the shell's prompt; keep only the marks. Re-applied every time,
  # after prompt themes have run, so it wins.
  PROMPT=$'%{\e]133;A\a%}%{\e]133;B\a%}'
  RPROMPT=''
  PS2=$'%{\e]133;A;k=s\a%}%{\e]133;B\a%}'
  # Stay the last precmd hook.
  precmd_functions=(${precmd_functions:#_swiftty_precmd} _swiftty_precmd)
}

_swiftty_preexec() {
  print -n "\e]133;C;cmdline_url=$(_swiftty_urlencode "$1")\a"
  _swiftty_running=1
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _swiftty_precmd
add-zsh-hook preexec _swiftty_preexec
