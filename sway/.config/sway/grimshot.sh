# Screenshots:

set $screenshot 1 save active, 2 save area, 3 save screen, 4 save window
mode "$screenshot" {
    bindsym 1 exec 'grimshot --notify save active', mode "default"
    bindsym 2 exec 'grimshot --notify save area', mode "default"
    bindsym 3 exec 'grimshot --notify save output', mode "default"
    bindsym 4 exec 'grimshot --notify save window', mode "default"

# back to normal: Enter or Escape
    bindsym Return mode "default"
    bindsym Escape mode "default"
    bindsym $mod+Print mode "default"
}

bindsym $mod+Print mode "$screenshot"
