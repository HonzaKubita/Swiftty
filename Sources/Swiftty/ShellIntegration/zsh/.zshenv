# Swiftty shell integration bootstrap.
# Swiftty starts zsh with ZDOTDIR pointing here. Put the user's ZDOTDIR back
# first, so zsh goes on to read their own .zprofile and .zshrc as usual.
if [[ -n "${SWIFTTY_ORIG_ZDOTDIR+X}" ]]; then
  ZDOTDIR="$SWIFTTY_ORIG_ZDOTDIR"
  unset SWIFTTY_ORIG_ZDOTDIR
else
  unset ZDOTDIR
fi

_swiftty_user_zshenv="${ZDOTDIR:-$HOME}/.zshenv"
[[ -r "$_swiftty_user_zshenv" ]] && source "$_swiftty_user_zshenv"
unset _swiftty_user_zshenv

if [[ -o interactive && -n "$SWIFTTY_INTEGRATION_DIR" ]]; then
  source "$SWIFTTY_INTEGRATION_DIR/swiftty.zsh"
fi
