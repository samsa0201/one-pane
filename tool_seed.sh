#!/usr/bin/env bash
# Prints the POCKET_SEED value for the local test sshd (see docs/architecture.md "Testing").
D=~/.local/share/tmux-pocket-test
python3 -c 'import json,base64,sys,os; print(base64.b64encode(json.dumps({"id":"test","name":"dev host (test sshd)","host":"10.0.2.2","port":2222,"user":os.environ["USER"],"tmuxCmd":"tmux -L pocket","session":"main","key":open(sys.argv[1]).read()}).encode()).decode())' "$D/client"
