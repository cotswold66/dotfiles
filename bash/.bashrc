#
# ~/.bashrc
# 

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

alias diff='diff --color=auto'
alias grep='grep --color=auto'
alias ip='ip -color=auto'
alias ls='ls --color=auto'
alias ll="ls -alh --color=auto"
alias nnn='tmux new -Asnnn "nnn -a -e"'
alias vi='vim'
PS1='[\u@\h \W]\$ '

bind '"\e[A": history-search-backward'
bind '"\eOA": history-search-backward'
bind '"\e[B": history-search-forward'
bind '"\eOB": history-search-forward'

export NNN_FIFO='/tmp/nnn.fifo'
export NNN_PLUG='p:preview-tui;v:imgview'
export NNN_TRASH=2
