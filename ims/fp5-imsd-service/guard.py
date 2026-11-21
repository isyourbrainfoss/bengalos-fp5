#!/usr/bin/python3
import os, sys, subprocess
from ownership import supported_kernel
if not supported_kernel(os.uname().release):
    sys.exit(1)  # ExecCondition skip, not a failed reboot

def src(path):
    return subprocess.check_output(
        ['findmnt', '-rn', '-T', path, '-o', 'SOURCE'], text=True
    ).strip()

# Keep the original safety intent: both IMS trees must live on the live OS
# root filesystem (SD /dev/mmcblk2p8, or the internal root loop over sda17),
# not on a foreign mount such as the auto-mounted SD while booted internally.
root = src('/')
if not root:
    sys.exit(1)
for p in ['/var/lib/fp5-imsd', '/opt/fp5-imsd']:
    if not os.path.isdir(p) or src(p) != root:
        sys.exit(1)
