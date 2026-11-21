/* Host unit test for cad_selectmode_decide. No PulseAudio. */
#include "cad-selectmode-decide.h"

#include <stdio.h>
#include <string.h>

static int passed, failed;

#define CHECK(cond, name) do { \
    if (cond) { printf("PASS %s\n", name); passed++; } \
    else { printf("FAIL %s\n", name); failed++; } \
} while (0)

static void zin(CadSelIn *in)
{
    memset(in, 0, sizeof *in);
    in->source_id = 2;
    in->sink_id = 3;
    in->has_voice = 1;
    in->retries_left = CAD_SELECT_RETRIES;
    in->target_available = 1;
}

static void test_enter(void)
{
    CadSelIn in;
    CadSelOut out;

    zin(&in);
    in.mode = 0;
    in.source_id = -1;
    in.sink_id = -1;
    in.phase = CAD_PHASE_ENTER;
    cad_selectmode_decide(&in, &out);
    CHECK(out.step == CAD_STEP_SET_PROFILE, "enter leave-call still switches profile");
    CHECK(out.skip_mute && out.skip_speaker, "enter leave-call skips missing source and sink");
    CHECK(out.arm_timeout, "enter arms the deadline");
    CHECK(out.retries_left == CAD_SELECT_RETRIES, "enter keeps the retry budget");

    zin(&in);
    in.mode = 1;
    in.phase = CAD_PHASE_ENTER;
    cad_selectmode_decide(&in, &out);
    CHECK(out.step == CAD_STEP_SET_PROFILE && out.skip_mute && out.skip_speaker,
          "enter call does not unmute or move speaker");

    zin(&in);
    in.mode = 0;
    in.has_voice = 0;
    in.sink_id = -1;
    in.phase = CAD_PHASE_ENTER;
    cad_selectmode_decide(&in, &out);
    CHECK(out.step == CAD_STEP_FAIL, "enter with no voice profile and no sink fails now");

    zin(&in);
    in.mode = 0;
    in.has_voice = 0;
    in.sink_id = 4;
    in.phase = CAD_PHASE_ENTER;
    cad_selectmode_decide(&in, &out);
    CHECK(out.step == CAD_STEP_SET_PROFILE && !out.skip_speaker,
          "enter without voice profile switches the sink port");
}

static void test_card_errors(void)
{
    CadSelIn in;
    CadSelOut out;

    zin(&in);
    in.phase = CAD_PHASE_CARD;
    in.eol = -1;
    cad_selectmode_decide(&in, &out);
    CHECK(out.step == CAD_STEP_FAIL, "card eol<0 completes with an error");

    zin(&in);
    in.phase = CAD_PHASE_CARD;
    in.eol = 1;
    cad_selectmode_decide(&in, &out);
    CHECK(out.step == CAD_STEP_FAIL, "card list ended with no decision completes with an error");

    zin(&in);
    in.phase = CAD_PHASE_CARD;
    in.eol = 1;
    in.queued = 1;
    in.queued_success = 1;
    cad_selectmode_decide(&in, &out);
    CHECK(out.step == CAD_STEP_OK, "queued success completes on eol>0");

    zin(&in);
    in.phase = CAD_PHASE_CARD;
    in.eol = 1;
    in.queued = 1;
    in.queued_success = 0;
    cad_selectmode_decide(&in, &out);
    CHECK(out.step == CAD_STEP_FAIL, "queued failure completes on eol>0");

    zin(&in);
    in.phase = CAD_PHASE_CARD;
    in.eol = 1;
    in.async_started = 1;
    cad_selectmode_decide(&in, &out);
    CHECK(out.step == CAD_STEP_IGNORE, "eol after set_card_profile does not complete again");
}

static void test_card_switch(void)
{
    CadSelIn in;
    CadSelOut out;

    zin(&in);
    in.phase = CAD_PHASE_CARD;
    in.eol = 0;
    in.mode = 0;
    in.active = CAD_ACTIVE_VOICE;
    in.already_there = 0;
    in.target_available = 1;
    cad_selectmode_decide(&in, &out);
    CHECK(out.step == CAD_STEP_SET_PROFILE && out.arm_timeout,
          "voice profile while leaving the call switches to HiFi");

    zin(&in);
    in.phase = CAD_PHASE_CARD;
    in.eol = 0;
    in.mode = 0;
    in.active = CAD_ACTIVE_HIFI;
    in.already_there = 1;
    cad_selectmode_decide(&in, &out);
    CHECK(out.step == CAD_STEP_IGNORE && out.queued && out.queued_success,
          "already on HiFi queues success and does not free on eol 0");

    zin(&in);
    in.phase = CAD_PHASE_PORT;
    in.eol = 0;
    in.already_there = 1;
    in.active = CAD_ACTIVE_HIFI;
    cad_selectmode_decide(&in, &out);
    CHECK(out.step == CAD_STEP_IGNORE && out.queued_success,
          "port already selected queues success");
}

static void test_retry(void)
{
    CadSelIn in;
    CadSelOut out;

    zin(&in);
    in.phase = CAD_PHASE_CARD;
    in.eol = 0;
    in.active = CAD_ACTIVE_UNKNOWN;
    in.target_available = 0;
    in.retries_left = 3;
    cad_selectmode_decide(&in, &out);
    CHECK(out.step == CAD_STEP_RETRY && out.retries_left == 2 && out.suppress_eol,
          "unknown profile retries and ignores the rest of this list");

    zin(&in);
    in.phase = CAD_PHASE_CARD;
    in.eol = 1;
    in.suppress_eol = 1;
    in.retries_left = 2;
    cad_selectmode_decide(&in, &out);
    CHECK(out.step == CAD_STEP_IGNORE && !out.suppress_eol,
          "suppressed eol does not fail the retried query");

    zin(&in);
    in.phase = CAD_PHASE_CARD;
    in.eol = 0;
    in.active = CAD_ACTIVE_UNKNOWN;
    in.target_available = 0;
    in.retries_left = 0;
    cad_selectmode_decide(&in, &out);
    CHECK(out.step == CAD_STEP_IGNORE && out.queued && !out.queued_success,
          "retry budget exhausted queues a failure");

    zin(&in);
    in.phase = CAD_PHASE_CARD;
    in.eol = 0;
    in.active = CAD_ACTIVE_HIFI;
    in.already_there = 0;
    in.target_available = 0;
    in.retries_left = 1;
    cad_selectmode_decide(&in, &out);
    CHECK(out.step == CAD_STEP_RETRY && out.retries_left == 0,
          "missing target profile retries once");
}

static void test_incident_then_next(void)
{
    CadSelIn in;
    CadSelOut out;

    /* 21.11 hangup: Voice Call ports already gone, then the card query fails. */
    zin(&in);
    in.mode = 0;
    in.source_id = -1;
    in.sink_id = -1;
    in.has_voice = 1;
    in.phase = CAD_PHASE_ENTER;
    cad_selectmode_decide(&in, &out);
    CHECK(out.step == CAD_STEP_SET_PROFILE && out.skip_mute && out.skip_speaker,
          "incident: missing ports do not block SelectMode");

    zin(&in);
    in.phase = CAD_PHASE_CARD;
    in.eol = -1;
    in.mode = 0;
    cad_selectmode_decide(&in, &out);
    CHECK(out.step == CAD_STEP_FAIL, "incident: card disappeared, SelectMode returns an error");

    /* A later SelectMode is a new operation. The daemon is not stuck. */
    zin(&in);
    in.mode = 1;
    in.phase = CAD_PHASE_ENTER;
    cad_selectmode_decide(&in, &out);
    CHECK(out.step == CAD_STEP_SET_PROFILE && out.arm_timeout,
          "next SelectMode is accepted after the failed one");

    /* Same for a timeout: the daemon completes FAIL, then a new enter works. */
    zin(&in);
    in.mode = 0;
    in.phase = CAD_PHASE_ENTER;
    cad_selectmode_decide(&in, &out);
    CHECK(out.step == CAD_STEP_SET_PROFILE, "SelectMode after a timeout is a fresh operation");
}

int main(void)
{
    test_enter();
    test_card_errors();
    test_card_switch();
    test_retry();
    test_incident_then_next();
    printf("selectmode: %d passed, %d failed\n", passed, failed);
    return failed ? 1 : 0;
}
