# Input driver registry

`ps_app_input_profile.c` is the authoritative table for VID/PID matching,
interface constraints, transport capabilities, and profile-specific fallback
timing. USB Host consumes the selected policy and timing; it does not match
controller product IDs.

To add a controller profile:

1. Add its VID/PID, interface match mask, capability flags, and transport timing
   to `ps_app_input_profile.c`.
2. Reuse a registered parser when the report format matches. Otherwise add a
   driver operation in `ps_app_input_driver.c` and keep protocol decoding in
   the appropriate parser module.
3. Add profile selection, effective policy, transport timing, and valid report
   fixtures to `tests/ps/test_input_driver_registry.c`. The strict host runner
   compiles the suite as C99 with warnings treated as errors.

The static registry has deterministic priority: exact Switch profile, known
VID/PID profile, then generic XInput interface. Input Service owns
`PsAppInputState`.

Generation-tagged attach, detach, and transport APIs require a nonzero
generation. The generation-less compatibility wrappers remain available: attach
allocates a generation, while legacy detach and interrupt-IN reports snapshot
the currently active generation when enqueued. The event service rejects a
snapshot that became stale before consumption.
