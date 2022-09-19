let skip_defaults_vim=1
set nocompatible

" activate line numbers
set number

let &t_SI = "\e[6 q"
let &t_SR = "\e[4 q"
let &t_EI = "\e[2 q"

" Set the leader key to space
let mapleader = " "

" disable relative line numbers, remove no to sample it
set norelativenumber

" turn info in tray on even if default
set ruler

" tabs are the devil
set expandtab
set tabstop=2
set softtabstop=2
set shiftwidth=2
set smartindent
set smarttab
set autoindent

" easier to see characters when `set paste` is on
set listchars=tab:→\ ,eol:↲,nbsp:␣,space:·,trail:·,extends:⟩,precedes:⟨

" enough for line numbers + gutter within 80 
set textwidth=73 

" more risky, but cleaner
set nobackup
set noswapfile
set nowritebackup

" keep the terminal title updated
set icon

" always show the statusline
set laststatus=2
set statusline=%.40F\ %m\ %y
set statusline+=%=        " Switch to the right side
set statusline+=%l        " Current line
set statusline+=/         " Separator
set statusline+=%L        " Total lines

" center the cursor always on the screen
set scrolloff=3

" highlight search hits,  \+<cr> to clear 
set hlsearch
set incsearch
set linebreak
map <silent> <leader><cr> :noh<cr>

" better case-sensitive defaults
set ignorecase
set smartcase

" stop complaints about switching buffer with changes
set hidden

" command history
set history=200

" here because plugins and stuff need it
syntax enable

" faster scrolling
set ttyfast

" allow sensing the filetype
filetype plugin on

" Install vim-plug if not already installed
" (Yes I know about Vim 8 Plugins. They suck.)
if empty(glob('~/.vim/autoload/plug.vim'))
  silent !curl -fLo ~/.vim/autoload/plug.vim --create-dirs
    \ https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
  autocmd VimEnter * PlugInstall
endif

call plug#begin()

" Plug 'godlygeek/tabular'
" Plug 'vim-pandoc/vim-pandoc'
" Plug 'vim-pandoc/vim-pandoc-syntax'
" Plug 'vim-pandoc/vim-rmarkdown'
" Plug 'jalvesaq/Nvim-R'
" Plug 'ervandew/screen'
" Plug 'christoomey/vim-tmux-navigator'
" Plug 'Lokaltog/vim-powerline'
" Plug 'nathangrigg/vim-beancount'   
" Plug 'vim-scripts/indentpython.vim'
" Plug 'nvie/vim-flake8'
" Plug 'krisajenkins/vim-pipe'
" Plug 'krisajenkins/vim-postgresql-syntax'
" Plug 'markonm/traces.vim'
" Plug 'kassio/neoterm'
Plug 'kana/vim-fakeclip'
" Plug 'chriskempson/base16-vim'
Plug 'tpope/vim-commentary'
Plug 'tpope/vim-surround'
Plug 'francoiscabrol/ranger.vim'
Plug 'ctrlpvim/ctrlp.vim'
Plug 'vim-airline/vim-airline'
Plug 'vim-airline/vim-airline-themes'
Plug 'jceb/vim-orgmode'

call plug#end()

runtime macros/matchit.vim

" let base16colorspace=256
" colorscheme base16-tomorrow-night

" enable omni-completion
set omnifunc=syntaxcomplete#Complete

" pane switching vi style (duh)
map <C-j> <C-W>j
map <C-k> <C-W>k
map <C-h> <C-W>h
map <C-l> <C-W>l

filetype plugin indent on
if has("autocmd")
  autocmd FileType ruby setlocal ts=2 sts=2 sw=2 expandtab
endif


" Editing a protected file as 'sudo'
cmap W w !sudo tee % >/dev/null<CR>

let g:airline_powerline_fonts=1
" let g:airline_theme='base16_tomorrow_night'
