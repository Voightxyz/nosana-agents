# Build log — Voight agents on Nosana GPUs

Chronological log of building one-click GPU agent hosting: a user picks "Nosana GPU" in the Voight dashboard and gets an autonomous agent on a dedicated GPU with a local model. Every claim below links to an on-chain, publicly verifiable artifact.

## API spike (Aug 8, 2026)

Validated the Nosana deployments API end to end before writing any infrastructure:

- Full lifecycle over REST: create (born `DRAFT`) → start → `RUNNING` with an on-chain job → stop → `STOPPED` → archive.
- **Create → live HTTPS service in 19.6s** (http-echo on the NVIDIA 3060 market, $0.048/h).
- **Create → first LLM completion in ~2.5 min** with Ollama pulling the model at boot; ~39 tokens/s once warm.
- Contract details the engine now encodes: credit-paid jobs require a timeout of **at least 3600s**; job-level failures surface only in the deployment **events feed** while the deployment status stays `RUNNING`; archive requires a fully-reached `STOPPED`.
- Exposed-service URLs are deterministic: `base58(sha512("opIndex:port:jobId"))[0..44].node.k8s.prd.nos.ci` — derived locally and verified against live jobs.

## The agent image (Aug 8-11)

`seenfinity/voight-gpu-agent` — Hermes runtime + Ollama in one container, gateway on :8642 as the only exposed port, no inference credential inside. Hardening chain discovered mostly through free local runs:

1. `aiohttp` is required or the gateway's api_server platform never starts (`uv sync --no-dev` omits it).
2. The gateway refuses keys under 16 chars — per-agent derived keys are 64-hex.
3. Hermes requires a ≥64K context window. qwen3 is capped at its 40,960 trained ceiling, so the default model became **Llama 3.1 8B** (128K native), served at 64K with flash attention + an 8-bit KV cache so weights + cache fit a 12GB 3060 (verified live, no OOM).
4. The generated config pins the same model Ollama serves.
5. Llama 3.1 is not a reasoning model — the config disables thinking so Ollama doesn't 400.

Also learned: Docker Hub buildx attestation manifests made Nosana nodes skip the image entirely (jobs sat QUEUED while idle nodes waited); pushing a plain manifest fixed claims back to seconds.

## End-to-end validation on real GPUs (Aug 10-12)

An agent with a fully local model answered through its gateway on a rented 3060, authenticated with its per-agent derived key:

| Check | Evidence |
| --- | --- |
| Live turn | job [`2a2Ndy89…L8Jwr`](https://dashboard.nosana.com/jobs/2a2Ndy89UDC8EdGKUizpEb8B7eAqQCuBGUpsgd4L8Jwr): *"I'm a helpful assistant running on the Nosana decentralized GPU network."* and `391` for 17×23 |
| Tool use | job [`EWwYnNWT…VQCqm`](https://dashboard.nosana.com/jobs/EWwYnNWTibyTz1gP3cxUPohunmeyBGCHZWMUWDgVQCqm): the agent ran a terminal command inside the GPU container and returned its exact output |
| Cold start | create → healthy gateway in **77s** on a warm-cached node |

## The deploy engine (Aug 8-12)

Shipped in the Voight platform (`Voightxyz/voight` PRs #253-#256):

- `host` field on agents: `voight` (managed cloud) or `nosana` (dedicated GPU) — one decision in the create wizard.
- Job definitions are built and passed through an explicit validation gate (single op, GPU required, VRAM floor, only the gateway port exposed, health check required, and no inference or platform credential may ride into a container a third-party operator can inspect).
- Per-agent domain-separated HMAC keys for the gateway and memory sync — a key lifted from one container never opens another agent's.
- Curated memory round-trips through the platform per file, hitting the same storage layout the managed-cloud mount uses, so an agent's memory is portable across hosts.
- Failure paths tear the deployment down exactly once (queue timeout, error events, unhealthy gateway), and the background reconciler is host-aware with ceilings sized to real queue+boot budgets.
- Separate queue (30 min) and boot (10 min) budgets — queued time is free and congested markets are real.

## Live in production (Aug 13)

First user-created GPU agent through the production dashboard, one click, no CLI:

| Artifact | Reference |
| --- | --- |
| Agent | `cmsrgth6x00024minz0de94ae` ("NosanaAgentTest"), created via the Voight dashboard wizard |
| Nosana deployment | `EXEco1Tn5G2pUumfcCZv3V4qP1qFxUFKvdGSxNSgaotE` |
| On-chain job | [`56R81gzb…ak8Lu`](https://dashboard.nosana.com/jobs/56R81gzbmSxxxp28CzE8aqWhP7oFjfL7foj9v2pak8Lu) — NVIDIA 3060 market, RUNNING |
| Image | [`seenfinity/voight-gpu-agent`](https://hub.docker.com/r/seenfinity/voight-gpu-agent) `@sha256:7730dcb0` |

The agent answered chat turns from the dashboard within minutes of creation, with inference running locally on its GPU.

## Lifecycle: honest state, wake, hourly renewal (Aug 17-20)

A GPU agent's job ends at its hourly timeout — the platform now treats that as a first-class lifecycle instead of a silent failure:

- **Honest state**: when the job ends, the deployment flips to `STOPPED` on Nosana's side; the platform detects it (a reconciler sweep plus an instant probe when a chat can't reach the gateway) and shows "GPU stopped" instead of a dead "Live" badge.
- **Wake**: a stopped agent restarts from a dashboard button, or simply by messaging it (web or Telegram) — one guarded transition, so racing wake attempts can never launch two deployments. Scheduled tasks wake their agent too, with a bounded retry while it boots.
- **Hourly renewal**: an agent that is actively being used no longer dies mid-conversation. The platform extends the *same* on-chain job (+3600s via `POST /jobs/{id}/extend`, which works on SIMPLE-strategy deployments and honors idempotency keys — verified live), so there is no cold start and the job id stays stable. Idle agents die honestly and wake on demand. Renewals respect a per-day hour cap.
- **Stable URLs**: deployments get a per-deployment domain at create (`endpoints[].url`) that survives job rotation — the engine now uses it as the agent's backend URL, with the per-job hash as fallback.
- Measured: extend +3600s on a live 3060 job cost $0.044 with an on-chain tx; replaying the same idempotency key returned the same tx with no double charge; early stops refund pro-rata to the second.

## Memory that survives job cycles (Aug 20)

GPU nodes have no persistent volume, so the agent's curated memory previously died with every job. `image/memory-sync.sh` now speaks the platform's per-file protocol (`GET/PUT $VOIGHT_MEMORY_URL/<file>` with base64-JSON bodies, per-agent bearer key): the container restores `MEMORY.md`/`USER.md` at boot and pushes changes periodically and at shutdown, with a per-file checksum gate so unchanged files cost zero requests. Protocol validated against a mock endpoint (restore, push, idempotent re-push, auth rejection) before baking the image.

## Node speed gate + automatic re-roll (Aug 26)

Live incident: an agent woke onto a market node that generated at a token-drip pace (a degraded host — the same container on a healthy 3060 does ~39 tok/s). Fix, in two halves:

- **In the image** (`start.sh`): after the model pull, a 48-token timed generation against the local Ollama measures the node's true generation rate (`eval_count/eval_duration` — prompt processing and load excluded). Below `MIN_TOKS_PER_SEC` (default 15, env-tunable, `0` disables) the boot logs `[speed-check] FAIL <n> tok/s — refusing this node` and exits 86 before the gateway ever comes up. On a pass, the probe doubles as a VRAM warm-up, so first turns start faster than before. Both paths verified inside the built image (FAIL: measured 5.5 tok/s vs a high threshold → exit 86 propagated as the container's exit code; PASS: `PASS 3.1 tok/s (min 1)` → boot continued).
- **In the deploy engine**: the boot health-wait now also watches the deployment status and treats an early death as "this node's problem" — it tears the deployment down and re-rolls a fresh one (which re-enters the market and lands on a different host in practice), with bounded retries before failing honestly. Queue congestion, credit exhaustion and API rejections stay fatal — a re-roll can't fix those, so it isn't attempted.

## Pin the framework (Aug 26)

The speed-gate rebuild surfaced a supply-chain footgun: the image installed hermes-agent from upstream `main`, so the rebuild silently jumped the framework from 0.20.4 to 0.20.5 (hundreds of upstream commits, several touching system-prompt composition) and deployed agents' conversational behavior visibly changed. `HERMES_REF` now defaults to a released upstream tag (`v2026.8.18` = 0.20.4, verified by booting the rebuilt image and reading the gateway's `/health` version). Framework upgrades are a deliberate, tested bump of that ref from now on.

## ZeroClaw GPU variant (Aug 31)

A second framework joins the GPU fleet: `image-zeroclaw/` packages the ZeroClaw
runtime (Rust, ~30MB binary copied from the digest-pinned upstream image) next
to Ollama, keeping every platform contract identical — :8642 gateway with
health-checked expose, pre-seeded bearer auth (pairing forced on), the boot
speed gate (rewritten in grep/awk — this image carries no Python), and no
inference key inside the container. Validated locally end to end: gate PASS,
pairing active, streamed turns over the gateway WebSocket with exact usage.

## Speed gate v2: measure warm, not cold (both images)

Live debugging on a real market node showed the boot speed gate was measuring
the model's very first generation after load — which also pays CUDA graph
compilation and the card's clock ramp. A healthy 3060 measured 2.5 tok/s on
that cold pass and 33 tok/s one generation later, so the gate was refusing
perfectly good hosts and exhausting the platform's node re-rolls.

Both images (Hermes and ZeroClaw variants) now run a short discarded warm-up
generation first, then measure, and retry the measurement up to three times
if the rate is still below threshold while the card ramps. The Ollama base is
now pinned by digest in both Dockerfiles (0.33.2, GPU path verified live on a
market node): a floating `:latest` base had silently changed the runtime under
the fleet on a rebuild. Images are pushed as plain single-arch manifests.

## GPU market catalog: 3090 and 4090 (shipped)

The platform now offers three markets — NVIDIA 3060, 3090, and 4090 — with
per-market pricing and live availability read straight from each market's
on-chain queue account (queue type + length decoded over public RPC, cached
briefly). The deploy wizard shows real "N available now" counts per market.

## Next

- Per-hour billing surfaced to users.
