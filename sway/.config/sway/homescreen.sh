#!/bin/bash
swaymsg "exec firefox"
sleep 2s
swaymsg 'exec $emacs'
sleep 1s
swaymsg "splitv"
swaymsg 'exec $term'
