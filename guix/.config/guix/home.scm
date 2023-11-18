(use-modules (gnu home)
             (gnu home services)
             (gnu home services gnupg)
             (gnu packages)
             (gnu packages gnupg)
             (gnu services)
             (guix gexp)
             (gnu home services shells))

(define %base16-config
  "\n# Base16 Shell
BASE16_SHELL=\"$HOME/src/base16-shell/\"
[ -n \"$PS1\" ] && \\
    [ -s \"$BASE16_SHELL/profile_helper.sh\" ] && \\
        source \"$BASE16_SHELL/profile_helper.sh\"
        
base16_tomorrow-night")

(home-environment
   (packages  
    (specifications->packages
     (list 
      "cryptsetup"
      "dconf-editor"
      "efibootmgr"
      "emacs-fd"
      "emacs-fzf"
      "emacs-geiser"
      "emacs-geiser-guile"
      "emacs-pgtk"                         ; pure GTK version of emacs for wayland
      "fd"
      "firefox-wayland" 
      "flatpak" 
      "font-adobe-source-code-pro"         ; used as default font in emacs
      "fzf"
      "gimp"
      "git"
      "gnome-mahjongg"
      "gnome-mines"
      "guile"
      "isync"
      "kmahjongg"
      "kshisen"
      "libreoffice"
      "lvm2"
      "mosh"
      "mu"
      "openssh" 
      "password-store" 
      "pdfarranger"
      "picmi"
      "restic"
      "ripgrep"
      "rsync"
      "stow"
      "telegram-desktop"
      "tmux"
      "vim"
      "virt-manager"
      "xdg-desktop-portal-gtk"             ; allows better theming in flatpak
      "xlsclients"
      "xrdb"
      "zoom"
      )))
    ;; Below is the list of Home services.  To search for available
    ;; services, run 'guix home search KEYWORD' in a terminal.
    (services
     (list 
      (service home-bash-service-type
               (home-bash-configuration
                (aliases '(("grep" . "grep --color=auto") ("la" . "ls -al")))
                (environment-variables 
                 '(("XDG_DATA_DIRS" . "$XDG_DATA_DIRS:$HOME/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share")
                   ("PATH" . "$HOME/bin:$PATH")
                   ("PASSWORD_STORE_DIR" . "$HOME/src/password-store")))
                (bashrc (list (plain-file "base16-config" %base16-config)))))
      ;; (simple-service 'dotfiles-service
      ;;                 home-files-service-type
      ;;                 `((".gitconfig" ,(local-file "./dot-gitconfig"))))
      (simple-service 'envars-service
                      home-environment-variables-service-type
                      `(("PLASMA_USE_QT_SCALING" . #t)
                        ("QT_AUTO_SCREEN_SCALE_FACTOR" . "1")
                        ("QT_ENABLE_HIGHDPI_SCALING" . "1")
                        ("XDG_SCREENSHOTS_DIR" . "$HOME/Screenshots")))
      (service home-gpg-agent-service-type
               (home-gpg-agent-configuration
                (pinentry-program
                 (file-append pinentry-gnome3 "/bin/pinentry-gnome3")))))))
