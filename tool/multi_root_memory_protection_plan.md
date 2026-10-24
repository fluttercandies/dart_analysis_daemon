# Multi-root memory protection plan

## Goal

Reduce the chance that an opt-in `DANA_MULTI_ROOT=1` pool pushes the machine
into paging or commit exhaustion, while preserving the active check and never
silently starting a second analyzer after the pool explicitly denies a join.
This is best-effort protection, not a hard memory cap or a guarantee against
the operating system terminating a process.

## Scope and behavior

- Scope is the multi-root pool only. `DANA_GLOBAL_BUDGET=1` remains a separate
  one-root-at-a-time mode.
- Before adding a root, enforce `DANA_POOL_MAX_ROOTS` and sample available
  physical/commit memory on supported platforms. Under pressure, evict one
  eligible root in LRU order and return promptly; do not wait for an active
  analysis or sleep in the serialized session request queue.
- Admission is fail-closed. If the sampler is unavailable, the configured root
  limit cannot be met, or memory remains below the startup reserve after an
  eviction, return a structured admission error. The CLI reports it on stderr
  and in its JSON result, exits with `75`, and does not start an independent
  analyzer. Callers should retry pressure denials only after recovery and the
  eviction cooldown.
- While the analyzer is idle, sample system memory periodically. Require
  consecutive low-memory samples before acting, then evict only roots that are
  not in a request and have exceeded a short idle grace period. Stop once the
  recovery reserve is met or no eligible root remains. Keep the pool's primary
  root and any in-flight request intact.
- Republish the pool registry after background eviction so future clients see
  the roots actually held by the analyzer. Log which roots were reclaimed.
- If pressure occurs during an active analysis, do not interrupt that request.
  The monitor may reclaim idle roots once the analyzer is idle; the OS can still
  reclaim or terminate processes before then.
- On macOS, kernel `warn` pressure is advisory; only `critical` pressure is
  converted into a zero-commit admission signal. Physical reserve checks still
  apply at every level. This exception applies only to new-root admission;
  the global single-worker budget retains the warn signal; the multi-root idle
  monitor uses the same advisory-warn rule as admission.

## Initial policy defaults

- Monitor interval: 2 seconds.
- Low-memory trigger: 2 consecutive samples below the existing global reserve.
- Runtime recovery target: existing reserve plus `recoveryBytes`.
- Recently-used root grace before runtime eviction: 10 seconds.
- Admission and runtime eviction share one 10-second post-eviction cooldown.
- New-root admission wait: no intentional wait. A root-limit denial is
  immediate when no root is eligible; after a pressure eviction, another
  pressure-driven admission is denied during the 10-second settle cooldown.
- Reuse the existing cross-platform `GlobalBudgetPolicy` and system samplers;
  do not introduce a per-root memory estimate or claim a hard cap.

## Implementation and acceptance tasks

1. [x] Add explicit admission outcomes (root-limit denial, memory pressure,
   active analysis, unavailable sampler) and enforce the configured root cap.
   Preserve roots evicted before an unsuccessful admission in the response.
2. [x] Make CLI pool-admission denial visible and non-zero, without falling
   back to a separate analyzer. Keep fallback for connection/pool failures.
3. [x] Add idle-only periodic monitoring, two-sample triggering, LRU/idle
   grace, recovery hysteresis, registry refresh, and timer cancellation.
4. [x] Add deterministic coverage for bounded denial, unavailable sampling,
   strict cap, denied admission after eviction, active-analysis protection,
   runtime LRU/hysteresis, CLI no-fallback, and pool-registry refresh decisions.
   The CLI integration also exercises stopping a pool owner with its monitor
   timer enabled.
5. [x] Run focused and full package tests, formatting and static analysis on
   Windows. macOS runtime behavior still requires the user's Mac verification.
6. [x] Update public README descriptions with the best-effort behavior and
   retain the limitation that active analysis is not preempted and the OS can
   still terminate the process.

## Explicit non-goals

- Do not kill or restart the analyzer in the middle of an active check.
- Do not change the default opt-in status of multi-root.
- Do not make the analyzer process or system memory usage a hard-limited
  resource; the current sampler reports system headroom, not a safe per-root
  allocation.
- Do not change the semantics of global single-worker mode in this task.

## Status

- Design: accepted for implementation.
- Core implementation/tests: complete on Windows; full package suite passed
  (200 passed, 1 skipped), and static analysis has no errors. Only existing
  informational style lints remain in the worktree probe script.
- macOS validation: pending a Mac environment.
