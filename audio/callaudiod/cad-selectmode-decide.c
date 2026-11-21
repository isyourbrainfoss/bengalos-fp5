/*
 * See cad-selectmode-decide.h.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "cad-selectmode-decide.h"

#include <string.h>

static void finish_list(const CadSelIn *in, CadSelOut *out)
{
    if (in->queued)
        out->step = in->queued_success ? CAD_STEP_OK : CAD_STEP_FAIL;
    else
        out->step = CAD_STEP_FAIL;
}

void cad_selectmode_decide(const CadSelIn *in, CadSelOut *out)
{
    if (!out)
        return;
    memset(out, 0, sizeof *out);
    if (!in) {
        out->step = CAD_STEP_FAIL;
        return;
    }

    out->retries_left = in->retries_left;
    out->queued = in->queued;
    out->queued_success = in->queued_success;
    out->suppress_eol = in->suppress_eol;
    out->skip_mute = in->source_id < 0;
    out->skip_speaker = in->sink_id < 0;

    /*
     * Upstream only unmutes and drops the speaker when leaving a call.
     * Entering a call must not run those side operations.
     */
    if (in->phase == CAD_PHASE_ENTER && in->mode != 0) {
        out->skip_mute = 1;
        out->skip_speaker = 1;
    }

    /*
     * A retry was armed on eol==0. The matching eol>0 belongs to the old
     * query and must not complete or fail the D-Bus call.
     */
    if (in->suppress_eol) {
        out->step = CAD_STEP_IGNORE;
        if (in->eol > 0)
            out->suppress_eol = 0;
        else
            out->suppress_eol = 1;
        return;
    }

    if (in->phase == CAD_PHASE_ENTER) {
        if (!in->has_voice && in->sink_id < 0) {
            out->step = CAD_STEP_FAIL;
            return;
        }
        out->step = CAD_STEP_SET_PROFILE;
        out->arm_timeout = 1;
        if (out->retries_left <= 0)
            out->retries_left = CAD_SELECT_RETRIES;
        return;
    }

    /* CARD and PORT: one PulseAudio info list. */
    if (in->async_started) {
        out->step = CAD_STEP_IGNORE;
        return;
    }
    if (in->eol < 0) {
        out->step = CAD_STEP_FAIL;
        return;
    }
    if (in->eol > 0) {
        finish_list(in, out);
        return;
    }

    /*
     * eol == 0. Do not complete yet: PulseAudio calls the callback again
     * with eol>0, and freeing here is the 0.1.99 use-after-free.
     */
    if (in->active == CAD_ACTIVE_UNKNOWN || !in->target_available) {
        if (in->retries_left > 0) {
            out->step = CAD_STEP_RETRY;
            out->retries_left = in->retries_left - 1;
            out->suppress_eol = 1;
            out->arm_timeout = 1;
            return;
        }
        out->queued = 1;
        out->queued_success = 0;
        out->step = CAD_STEP_IGNORE;
        return;
    }
    if (in->already_there) {
        out->queued = 1;
        out->queued_success = 1;
        out->step = CAD_STEP_IGNORE;
        return;
    }
    out->step = CAD_STEP_SET_PROFILE;
    out->arm_timeout = 1;
}
