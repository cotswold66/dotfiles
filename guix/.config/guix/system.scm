
(use-modules (gnu)
             (gnu services virtualization)
             (gnu services avahi)
             (gnu services networking)
             (gnu system nss)
             (gnu packages firmware)
             (nongnu packages linux))
(use-package-modules fonts)
(use-service-modules cups desktop docker networking nix ssh xorg)

(operating-system
  (kernel linux)
  (firmware (list linux-firmware))
  (locale "en_US.utf8")
  (timezone "America/Chicago")
  (keyboard-layout (keyboard-layout "dk"))
  (host-name "pluto")

  (name-service-switch %mdns-host-lookup-nss)

  ;; The list of user accounts ('root' is implicit).
  (users (cons* (user-account
                  (name "john")
                  (comment "John Lord")
                  (group "users")
                  (home-directory "/home/john")
                  (supplementary-groups '("wheel" "netdev" "audio" "video"
                                          "kvm" "libvirt" "docker" "lp")))
                %base-user-accounts))

  ;; Packages installed system-wide.  Users can also install packages
  ;; under their own account: use 'guix search KEYWORD' to search
  ;; for packages and 'guix install PACKAGE' to install a package.
  (packages (append (map specification->package
                         '("nss-certs" 
                           "font-terminus"
                           "intel-media-driver-nonfree"
                           "libvdpau-va-gl"
                           "ovmf"))
                    %base-packages))

  ;; Below is the list of system services.  To search for available
  ;; services, run 'guix system search KEYWORD' in a terminal.
  (services
   (append (list (service gnome-desktop-service-type)
                 (service cups-service-type
                          (cups-configuration
                           (web-interface? #t)))
                 (service gnome-keyring-service-type)
                 (service libvirt-service-type
                          (libvirt-configuration
                           (unix-sock-group "libvirt")
                           (tls-port "16555")))
                 (service nftables-service-type)
                 (service virtlog-service-type)
                 (service docker-service-type)
                 (service nix-service-type)
                 (extra-special-file "/usr/share/OVMF/OVMF_CODE.fd"
                    (file-append ovmf "/share/firmware/ovmf_x64.bin"))
                 (extra-special-file "/usr/share/OVMF/OVMF_VARS.fd"
                    (file-append ovmf "/share/firmware/ovmf_x64.bin"))
                 ;; (simple-service 'subugid-config etc-service-type
                 ;;                 `(("subuid" ,(plain-file "subuid"
                 ;;                                          "john:100000:65536\n"))
                 ;;                   ("subgid" ,(plain-file "subgid"
                 ;;                                          "john:100000:65536\n"))))
                 ;; (simple-service 'containers etc-service-type
                 ;;                 `(("containers/storage.conf" 
                 ;;                    ,(plain-file "containers-storage.conf"
                 ;;                                 "[storage]\ndriver = \"overlay\"\n"))
                 ;;                   ("containers/policy.json"
                 ;;                    ,(local-file "files/policy.json"))))
                 (set-xorg-configuration
                  (xorg-configuration (keyboard-layout keyboard-layout))))

           ;; This is the default list of services we
           ;; are appending to.
           (modify-services %desktop-services
                (gdm-service-type config => (gdm-configuration
                                             (inherit config)
                                             (wayland? #t)))
                (console-font-service-type config =>
                                           (map (lambda (tty)
                                                  (cons tty (file-append
                                                             font-terminus
                                                             "/share/consolefonts/ter-132b")))
                                                '("tty1" "tty2" "tty3" "tty4" "tty5" "tty6")))
                (guix-service-type config =>
                                   (guix-configuration
                                    (inherit config)
                                    (substitute-urls
                                     (append (list "https://guix.bordeaux.inria.fr"
                                                   "https://substitutes.nonguix.org")
                                             %default-substitute-urls))
                                    (authorized-keys
                                     (append (list (local-file "files/science.pub")
                                                   (local-file "files/nonguix.pub"))
                                             %default-authorized-guix-keys)))))))
  (bootloader (bootloader-configuration
                (bootloader grub-efi-bootloader)
                (targets (list "/boot/efi"))
                (keyboard-layout keyboard-layout)
                (theme (grub-theme
                        (inherit (grub-theme))
                        (gfxmode '("1600x1200x32" "auto"))))))

  (mapped-devices (list (mapped-device
                          (source (uuid
                                   "489a6bfb-83a5-4cd2-a35b-fd7f4ab06f0a"))
                          (target "cryptroot")
                          (type luks-device-mapping))))

  ;; The list of file systems that get "mounted".  The unique
  ;; file system identifiers there ("UUIDs") can be obtained
  ;; by running 'blkid' in a terminal.
  (file-systems (cons* (file-system
                         (mount-point "/boot/efi")
                         (device (uuid "2548-F30B"
                                       'fat32))
                         (type "vfat"))
                       (file-system
                         (mount-point "/")
                         (device "/dev/mapper/cryptroot")
                         (type "ext4")
                         (dependencies mapped-devices)) %base-file-systems)))
