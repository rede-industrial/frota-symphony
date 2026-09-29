# Fase 0: worker admission candidate
Canonical constitution: AbrahaoLima/frota-governanca main 8991b76eae7be87a55bea93383d65d73edc9e7a6, governance/FROTA-documento-mestre-v1.8.md.
Scope: GH-181; existing Carla diagnostic correction from 3df524d, isolated from the original dirty checkout.
Status: BLOCKED FOR LIVE ADMISSION. No merge, runtime deployment, restart, retry of GH-173, credentials or firewall changes.
Evidence collected on TRUCK sigmaserver, SSH sigma@192.168.2.186, via AUX Desktop Commander on 2026-09-29.
- Original app-server test suite: 25 tests, 1 timeout (malformed JSON escaping in Windows fixture).
- Candidate suite: 25 tests, 0 failures, including denial of administrative command.
- Updated candidate: lint and specs check pass after grouping approval context and small lint-only simplifications.
- Final make all: PASS on 2026-09-29 16:32 America/Sao_Paulo. 365 tests, 0 failures, 6 skipped; coverage 100.00%, threshold preserved. Build, format, lint, specs and Dialyzer pass (0 type errors).
- Added admission regressions for schema, routing, completion, fail-closed promotion, Windows prompt and SSH input. Fixtures do not constitute live worker proof.
- Candidate built executable SHA256: 2169d2d6fc897e816e367b712351ca63d3c92af5edb53cc7cf5a9902e1b0193d.
- Live Symphony: running=0, retrying=0; GH-173 completion remains DELIVERY_INCOMPLETE.
- Local protocol fixtures are simulated test peers, not live Windows worker evidence.
Security corrections: quoted executable normalization now recognizes only C:\Windows\System32\cmd.exe; bounded diagnostics receive a per-command accept decision. Administrative commands, chained commands, a fake cmd.exe path and outside-workspace requests are covered by negative cases. Independent review remains mandatory.
Required next steps: independent PR review; applicable human gate; then exactly one restricted live pilot using the verified installed admission mechanism.
Preserved controls: on-request, workspace-write, concurrency 1, four turns, retry <=3, FinOps and kill switch verification before dispatch.
Rollback: candidate is isolated; leaving the live runtime unchanged is the current safe state. Any future deployment must record the previous executable hash/configuration and an exact rollback before installation.
Product delivery forecast: pending admission blocker. Administrator/console owns diagnosis; partida forecast remains pending independent review, human gate and live-pilot proof. Diagnosis checkpoint published 2026-09-29 16:11 America/Sao_Paulo; no unattended execution promised. This is not factory homologation.

Supervisor discovery: frota-symphony.service is a sigma user service, ExecStart /home/sigma/frota/runtime/symphony/start-symphony.sh. The running BEAM working directory is the original command-87 checkout. Replacing the legacy runtime escript alone would not prove the candidate is active. Runtime and workflow remain unchanged.
