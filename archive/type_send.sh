#!/bin/bash
MON=/root/steamos-nvkvm/mon.sock
text="$1"
for i in $(seq 1 80); do echo "sendkey backspace" | socat - unix:"$MON" >/dev/null; done
sleep 0.2
i=0
len=${#text}
while [ $i -lt $len ]; do
  c="${text:$i:1}"
  case "$c" in
    " ") k="spc" ;;
    "/") k="slash" ;;
    "-") k="minus" ;;
    ".") k="dot" ;;
    "_") k="shift-minus" ;;
    "|") k="shift-backslash" ;;
    ">") k="shift-dot" ;;
    "<") k="shift-comma" ;;
    "&") k="shift-7" ;;
    "*") k="shift-8" ;;
    "{") k="shift-bracket_left" ;;
    "}") k="shift-bracket_right" ;;
    "+") k="shift-equal" ;;
    "$") k="shift-4" ;;
    "'") k="apostrophe" ;;
    ":") k="shift-semicolon" ;;
    "=") k="equal" ;;
    ",") k="comma" ;;
    [A-Z]) k="shift-$(echo "$c" | tr 'A-Z' 'a-z')" ;;
    *) k="$c" ;;
  esac
  echo "sendkey $k" | socat - unix:"$MON" >/dev/null
  sleep 0.05
  i=$((i+1))
done
sleep 0.15
echo "sendkey ret" | socat - unix:"$MON" >/dev/null
