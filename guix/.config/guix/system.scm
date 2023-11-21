(use-modules (gnu)
             (gnu services virtualization)
             (gnu services avahi)
             (gnu services networking)
             (gnu system nss)
             (nongnu packages linux))
(use-package-modules fonts)
(use-service-modules cups desktop docker networking ssh xorg)

(define cryptroot
  (mapped-device
   (source (uuid
            "0161c370-2b8d-4a69-9306-c8f70b005e9a"))
   (target "guix")
   (type luks-device-mapping)))

(define crypthome
  (mapped-device
   (source (uuid
            "230e52a9-59f8-447c-bfa9-b1a17ba397d3"))
   (target "crypthome")
   (type luks-device-mapping)))

(define vgpluto
  (mapped-device
   (source "pluto")
   (targets (list "pluto-home"))
   (type lvm-device-mapping)))

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
                  (home-directory "/home/guix")
                  (supplementary-groups '("wheel" "netdev" "audio" "video"
                                          "libvirt" "docker" "lp")))
                %base-user-accounts))

  ;; Packages installed system-wide.  Users can also install packages
  ;; under their own account: use 'guix search KEYWORD' to search
  ;; for packages and 'guix install PACKAGE' to install a package.
  (packages (append (map specification->package
                         '("nss-certs" 
                           "font-terminus"
                           "intel-media-driver-nonfree"
                           "libvdpau-va-gl"))
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
                (menu-entries
                 (list
                  (menu-entry
                   (label "Arch Linux")
                   (device (uuid "2548-F30B" 'fat))
                   (chain-loader "/EFI/Arch/grubx64.efi"))
                  (menu-entry
                   (label "Windows 11")
                   (device (uuid "2548-F30B" 'fat))
                   (chain-loader "/EFI/Microsoft/Boot/bootmgfw.efi"))))
                (theme (grub-theme
                        (inherit (grub-theme))
                        (gfxmode '("1600x1200x32" "auto"))))))

  (mapped-devices (list cryptroot
                        crypthome
                        vgpluto))

  ;; The list of file systems that get "mounted".  The unique
  ;; file system identifiers there ("UUIDs") can be obtained
  ;; by running 'blkid' in a terminal.
  (file-systems (cons* (file-system
                         (mount-point "/")
                         (device "/dev/mapper/guix")
                         (type "ext4")
                         (dependencies (list cryptroot)))
                       (file-system
                         (mount-point "/home")
                         (device "/dev/pluto/home")
                         (type "ext4")
                         (dependencies (list vgpluto)))
                       (file-system
                         (mount-point "/boot/efi")
                         (device (uuid "2548-F30B"
                                       'fat32))
                         (type "vfat"))
                       %base-file-systems)))
