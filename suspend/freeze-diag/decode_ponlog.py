#!/usr/bin/env python3
# Decode the PMK8350 PMIC PON log (stock qcom pmic-pon-log format) from a fp5-pon-capture file or a hex dump of SDAM5 0x7440-0x74bf.
import sys
# rows start at SDAM offset 0x40 (register 0x7440)
txt = open(sys.argv[1]).read()
if '## SDAM5' in txt:
    txt = txt.split('## SDAM5',1)[1].split('\n',1)[1].split('##',1)[0]
b = bytes.fromhex(txt)
reg = lambda off: b[off-0x40]
push = reg(0x46); start, end = 0x4B, 0xBF; FS = end-start+1
fifo = [reg(o) for o in range(start, end+1)]
EV={1:"PON_TRIGGER",2:"OTP_COPY",3:"TRIM",4:"XVLO_CHECK",5:"PMIC_CHECK",6:"RESET_TRIGGER",7:"RESET_TYPE",8:"WARM_RESET_COUNT",9:"FAULT_REASON_1_2",0xA:"FAULT_REASON_3",0xB:"PBS_PC_AT_FAULT",0xC:"FUNDAMENTAL_RESET",0xD:"PON_SEQ_START",0xE:"PON_SUCCESS",0xF:"WAITING_ON_PSHOLD",0x20:"VREG_READY_CHECK"}
ST={0:"FAULT0",1:"PON",2:"POFF",3:"ON",4:"RESET",5:"OFF",6:"FAULT6",7:"WARM_RESET"}
PT={0x84:"PS_HOLD",0x85:"HARD_RESET",0x86:"RESIN_N",0x87:"KPDPWR_N",0x621:"RTC_ALARM",0x640:"SMPL",0x8732:"USB_CHARGER(PM7250B)"}
RT={0x80:"KPDPWR_N_S2",0x81:"RESIN_N_S2",0x82:"KPDPWR+RESIN_S2",0x83:"PMIC_WATCHDOG_S2",0x84:"PS_HOLD",0x85:"SW_RESET",0x86:"RESIN_N_DEBOUNCE",0x87:"KPDPWR_N_DEBOUNCE",0x21E3:"SID2_BCL_ALARM",0x31F5:"SID3_BCL_ALARM",0x11D0:"SID1_OCP",0x21D0:"SID2_OCP"}
RTY={1:"WARM_RESET",4:"SHUTDOWN",7:"HARD_RESET"}
F1=["GP_FAULT0","GP_FAULT1","GP_FAULT2","GP_FAULT3","MBG_FAULT","OVLO","UVLO","AVDD_RB"]
F2=["?0","?1","PMIC_RB","FAULT_N","FAULT_WATCHDOG","PBS_NACK","RESTART_PON","OVERTEMP_STAGE3"]
bits=lambda v,t:",".join(t[i] for i in range(8) if v>>i&1) or "None"
endi = push-start; n = (FS)//4; st = (endi - n*4) % FS
for i in range(n):
    e=[fifo[(st+4*i+k)%FS] for k in range(4)]
    s,ev,d1,d0=e; d=(d1<<8)|d0
    if ev==1: x=PT.get(d,f"SID={d1>>4} PID=0x{(d>>4)&0xff:02X} IRQ={d0&7}")
    elif ev==6: x=RT.get(d,f"SID={d1>>4} PID=0x{(d>>4)&0xff:02X} IRQ={d0&7}")
    elif ev==7: x=RTY.get(d0,str(d0))
    elif ev==9: x=f"FR1={bits(d0,F1)} FR2={bits(d1,F2)}"
    elif ev==0xC: x=f"PBL={d1:#x} S3={d0:#x}"
    elif ev==0xB: x=f"pc=0x{d:04X}"
    elif ev==5: x=f"sidmask=0x{d:04X}"
    else: x=f"data=0x{d:04X}"
    print(f"{i:2} {' '.join('%02x'%v for v in e)}  {ST.get(s,s):10} {EV.get(ev,hex(ev)):18} {x}")
