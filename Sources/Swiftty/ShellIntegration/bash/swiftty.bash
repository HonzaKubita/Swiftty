# Swiftty shell integration for bash (4.4+).
#
# Started as `bash --rcfile swiftty.bash -i`: loads the user's startup files,
# then hides the prompt and reports each command with OSC 133 and the
# directory with OSC 7, so Swiftty can draw its native prompt and blocks.

# Login-shell startup files first, as a login shell would read them.
[ -r /etc/profile ] && . /etc/profile
if [ -r "$HOME/.bash_profile" ]; then . "$HOME/.bash_profile"
elif [ -r "$HOME/.bash_login" ]; then . "$HOME/.bash_login"
elif [ -r "$HOME/.profile" ]; then . "$HOME/.profile"
fi
# Most .bash_profile files load .bashrc; load it if this one didn't.
if [ -z "$_SWIFTTY_BASHRC_DONE" ] && [ -r "$HOME/.bashrc" ] && ! grep -q bashrc "$HOME/.bash_profile" 2>/dev/null; then
  _SWIFTTY_BASHRC_DONE=1
  . "$HOME/.bashrc"
fi

export SWIFTTY=1
export TERM_PROGRAM=Swiftty
_swiftty_last_hist=""
_swiftty_ret=0

_swiftty_urlencode() {
  local LC_ALL=C s="$1" out="" c i
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_/-]) out+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

# _swiftty_report: prints the state Swiftty's plugins ask for (git branch, …).
[ -r "$SWIFTTY_INTEGRATION_DIR/report.sh" ] && . "$SWIFTTY_INTEGRATION_DIR/report.sh"

_swiftty_save_ret() { _swiftty_ret=$?; }

_swiftty_prompt() {
  # A new history entry means a command ran since the last prompt.
  local h
  h=$(HISTTIMEFORMAT= builtin history 1)
  if [ -n "$_swiftty_last_hist" ] && [ "$h" != "$_swiftty_last_hist" ]; then
    printf '\e]133;D;%s\a\n' "$_swiftty_ret"
  fi
  _swiftty_last_hist="$h"
  printf '\e]7;file://%s%s\a' "$HOSTNAME" "$(_swiftty_urlencode "$PWD")"
  declare -F _swiftty_report >/dev/null && _swiftty_report
  PS1='\[\e]133;A\a\]\[\e]133;B\a\]'
  PS2='\[\e]133;A;k=s\a\]\[\e]133;B\a\]'
}

_swiftty_preexec() {
  local cmd
  cmd=$(HISTTIMEFORMAT= builtin history 1 | sed 's/^ *[0-9]* *//')
  printf '\e]133;C;cmdline_url=%s\a' "$(_swiftty_urlencode "$cmd")"
}

PROMPT_COMMAND="_swiftty_save_ret${PROMPT_COMMAND:+; $PROMPT_COMMAND}; _swiftty_prompt"
PS0='$(_swiftty_preexec)'
_swiftty_prompt >/dev/null 2>&1 || true
_swiftty_last_hist=$(HISTTIMEFORMAT= builtin history 1)
