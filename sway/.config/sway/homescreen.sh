#!/bin/bash
swaymsg "exec firefox"
sleep 2s
swaymsg 'exec emacsclient -a "" -c ~'
sleep 2s
swaymsg "splitv"
swaymsg "exec alacritty"
