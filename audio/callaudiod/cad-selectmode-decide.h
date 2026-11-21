/*
 * Decision helper for callaudiod 0.1.99 SelectMode.
 *
 * The PulseAudio backend calls this and does the I/O itself. This file has
 * no PulseAudio and no GLib types, so the host build can unit-test it.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#ifndef CAD_SELECTMODE_DECIDE_H
#define CAD_SELECTMODE_DECIDE_H

enum {
    CAD_STEP_OK = 0,          /* complete the D-Bus call successfully now */
    CAD_STEP_FAIL = 1,        /* complete the D-Bus call with an error now */
    CAD_STEP_SET_PROFILE = 2, /* start the async PulseAudio operation */
    CAD_STEP_RETRY = 3,       /* ask PulseAudio again after a short delay */
    CAD_STEP_IGNORE = 4       /* do not complete and do not free */
};

enum {
    CAD_PHASE_ENTER = 0, /* before any PulseAudio info query */
    CAD_PHASE_CARD = 1,  /* pa_context_get_card_info callback */
    CAD_PHASE_PORT = 2   /* pa_context_get_sink_info callback */
};

enum {
    CAD_ACTIVE_UNKNOWN = 0,
    CAD_ACTIVE_VOICE = 1,
    CAD_ACTIVE_HIFI = 2,
    CAD_ACTIVE_OTHER = 3
};

/* Short bound: 5 retries, 200 ms apart, under the 2.5 s SelectMode timeout. */
#define CAD_SELECT_RETRIES 5

typedef struct {
    int mode;             /* 0 = default (HiFi), 1 = voice call */
    int has_voice;        /* card has a Voice Call profile */
    int source_id;        /* <0 : no usable source */
    int sink_id;          /* <0 : no usable sink */
    int phase;
    int eol;              /* <0 error, 0 one info item, >0 end of list */
    int active;           /* CAD_ACTIVE_* */
    int target_available; /* a suitable target profile or port exists */
    int already_there;    /* active profile or port is already the target */
    int async_started;    /* set_card_profile / set_sink_port is in flight */
    int queued;           /* a result is waiting for eol>0 */
    int queued_success;
    int retries_left;
    int suppress_eol;     /* ignore the rest of this PulseAudio list */
} CadSelIn;

typedef struct {
    int step;
    int skip_mute;        /* do not call mute-mic (source already gone) */
    int skip_speaker;     /* do not call enable-speaker (sink already gone) */
    int arm_timeout;      /* arm the SelectMode deadline if not armed yet */
    int retries_left;
    int queued;
    int queued_success;
    int suppress_eol;
} CadSelOut;

void cad_selectmode_decide(const CadSelIn *in, CadSelOut *out);

#endif
