#
# ~/.bash_profile
#
# User specific environment

if ! [[ "$PATH" =~ "$HOME/context/tex/texmf-linux-64/bin::$HOME/.local/bin:$HOME/bin:" ]]
then
    PATH="$HOME/context/tex/texmf-linux-64/bin::$HOME/.local/bin:$HOME/bin:$PATH"
fi
export PATH

export B2_ACCOUNT_ID=001fcd061368b830000000002
export B2_ACCOUNT_KEY=K001d7VjWLgjEdQXFhqvn8QUeW84sns
# export RESTIC_PASSWORD_COMMAND='pass show backup/pluto'
export RESTIC_PASSWORD='LzjQVnS8tkCrhNYVcExS'

export MOZ_ENABLE_WAYLAND=1
export EDITOR='vim'
export VIEWER='vim'
export HISTFILESIZE=100000
export HISTSIZE=100000
export WORKON_HOME=~/src
export SSH_AUTH_SOCK=/run/user/1000/keyring/ssh
export LESS='-R --use-color -Dd+r$Du+b'
export QT_AUTO_SCREEN_SCALE_FACTOR=1
export NIX_PATH=$HOME/.nix-defexpr/channels:/nix/var/nix/profiles/per-user/root/channels${NIX_PATH:+:$NIX_PATH}

[[ -f ~/.bashrc ]] && . ~/.bashrc
