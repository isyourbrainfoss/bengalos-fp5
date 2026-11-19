import subprocess, glob, bisect
g=[f for f in glob.glob('/var/lib/upower/history-charge-*PM7250B*.dat')][0]
hist=[]
for l in open(g):
    p=l.split()
    if len(p)==3 and p[2] in ('discharging','charging','fully-charged','pending-charge'): hist.append((int(p[0]),float(p[1]),p[2]))
hist.sort(); ts=[h[0] for h in hist]
tot_h=tot_p=n=0; longs=[]
for b in range(-16,0):
    out=subprocess.run(['journalctl','-b',str(b),'-k','-o','short-unix','--no-pager','-g','PM: suspend (entry|exit)'],capture_output=True,text=True).stdout.splitlines()
    e=None
    for l in out:
        try: t=float(l.split()[0])
        except (ValueError, IndexError): continue
        if t<1.7e9: e=None; continue          # before clock sync
        if 'entry' in l: e=t
        elif e:
            i=bisect.bisect_right(ts,e)-1; j=bisect.bisect_left(ts,t)
            if i>=0 and j<len(hist) and hist[i][2]=='discharging' and hist[j][2]=='discharging':
                h=(t-e)/3600
                if h>=0.25: tot_h+=h; tot_p+=hist[i][1]-hist[j][1]; n+=1
            e=None
print(f"baseline (journal+upower, suspends >=15 min on battery, boots -16..-1): n={n} hours={tot_h:.2f} drop={tot_p:.0f}% -> {tot_p/tot_h if tot_h else 0:.2f} %/h")
