#!/usr/bin/python3
"""Hard secret scan (binary-safe). usage: secretscan.py DIR  -> prints 'HARD-HIT <rule> <path>' lines, exit 1 if any.
Rules: real PEM/OpenSSH private keys (header + key body, not mere magic strings as in libgio or the mime db),
SSH public keys (authorized_keys/host-key material), the lab phone serial, the lab user name, lab paths, the SIM-PIN
file name, and Wi-Fi PSK assignments with a value."""
import os, re, sys
RULES=[('private-key',re.compile(rb'-----BEGIN [A-Z ]*PRIVATE KEY[A-Z ]*-----\r?\n(?:[A-Za-z0-9-]+: [^\n]*\r?\n)*\r?\n?[A-Za-z0-9+/=]{40,}')),
       ('ssh-pubkey',re.compile(rb'(?:ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521)) AAAA[0-9A-Za-z+/]{40,}')),
       ('wifi-psk',re.compile(rb'(?:^|[\s"])(?:psk|wpa-psk|Passphrase|PreSharedKey)\s*=\s*[^\s"\']{8,}',re.M))]
# Lab identifiers (phone serial, lab user, lab paths) are NOT kept in this public repo: they come from the
# untracked file named by $FP5_LAB_PATTERNS ("name<TAB>regex" per line). Missing file = hard failure (fail closed).
lp=os.environ.get('FP5_LAB_PATTERNS','/auto/lab-patterns.local')
try:
    for l in open(lp,'rb'):
        l=l.rstrip(b'\n')
        if l and not l.startswith(b'#'):
            n,rx=l.split(b'\t',1); RULES.append((n.decode(),re.compile(rx)))
except OSError:
    print('HARD-HIT lab-patterns-missing',lp); sys.exit(1)
hits=0
for r,ds,fs in os.walk(sys.argv[1],followlinks=True):
    for f in fs:
        p=os.path.join(r,f)
        if os.path.islink(p) or not os.path.isfile(p) or os.path.getsize(p)>300*1024*1024: continue
        b=open(p,'rb').read()
        for n,rx in RULES:
            if rx.search(b): print('HARD-HIT',n,os.path.relpath(p,sys.argv[1])); hits+=1
sys.exit(1 if hits else 0)
