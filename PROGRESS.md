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

## Next

- Hour-block renewal (SIMPLE-EXTEND/INFINITE) so GPU agents outlive a single job window.
- 3090/4090 markets (visible in the wizard as coming soon).
- Per-hour billing surfaced to users.
