@echo off
rem Explorer-double-click launcher for the consumer controller bootstrap.
rem The real logic lives in bootstrap-controller.sh and runs inside WSL
rem (all Ansible work is Linux-side); this just invokes it through wsl and
rem holds the window open so the operator can read the result before the
rem cmd window closes.
wsl -- ./ops/bootstrap-controller.sh %*
pause
