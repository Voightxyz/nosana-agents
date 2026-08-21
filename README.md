# Voight Nosana Agents

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![Runtime](https://img.shields.io/badge/runtime-Hermes-blue.svg)
![Inference](https://img.shields.io/badge/inference-local%20GPU-brightgreen.svg)
[![Image](https://img.shields.io/badge/image-seenfinity%2Fvoight--gpu--agent-informational.svg)](https://hub.docker.com/r/seenfinity/voight-gpu-agent)

**One-click autonomous agents on [Nosana](https://nosana.com) decentralized GPUs. The model lives inside the container; the compute is verifiable on-chain.**

This repository contains the container image and deployment tooling behind [Voight](https://voight.xyz)'s GPU-hosted agents. A user picks **Nosana GPU** in the Voight dashboard and the platform's deploy engine provisions a dedicated GPU job running this image: one job = one agent, with its own GPU, its own local model, and zero inference credentials to leak.

```
                    Voight dashboard ─── one click ───┐
                                                      ▼
              ┌──────────────── deploy engine ────────────────┐
              │  build job definition → validate → create →   │
              │  start → wait for on-chain job → health-check │
              └──────────────────────┬───────────────────────┘
                                     ▼
┌─────────────────────────── Nosana GPU job ───────────────────────────┐
│                                                                      │
│   Ollama (127.0.0.1:11434)   ◄──  Hermes agent runtime               │
│   Hermes 3 8B · 64K ctx          gateway on :8642, the ONLY         │
│   loopback only                   exposed port, key-protected        │
│                                                                      │
│   memory-sync: restore at boot ── push on interval + shutdown        │
└──────────────────────────────────────────────────────────────────────┘
              ▲                                     │
        docker.io image              stable per-deployment domain
        (this repository)            (survives job rotation), backed by
                                      a verifiable on-chain job
```

## Why a local model

Agents on decentralized compute have a credential problem: anything placed in a container can be inspected by the node operator running it. Shipping an inference API key means trusting every node with your token spend. This image dissolves the problem instead of mitigating it: **the model runs inside the job, on the job's own GPU, so no inference key exists at all**. What remains in the container is scoped and revocable per agent (a gateway key and a memory token, both derived per agent).

Every deployment is also a real Solana account: the job, its GPU market, the executing node, and its timings are independently verifiable on the [Nosana dashboard](https://dashboard.nosana.com) — the same on-chain surface the [`@voightxyz/nosana`](https://github.com/Voightxyz/Nosana-SDK) SDK observes.

## How a deploy works

1. The deploy engine builds a job definition from this repository's [template](job/agent.template.json): the public image, per-agent env, and the gateway port with a continuous HTTP health check.
2. The definition passes an **explicit validation gate** before posting: exactly one GPU operation, a VRAM floor, only port 8642 exposed, a health check present, and a hard veto on any inference or platform credential riding into the container.
3. The deployment is created and started through Nosana's deployments API; the engine waits for the on-chain job, derives the service URL locally, and probes `/health` until the gateway is live.
4. Ready means ready: the agent's first chat turn works the moment the platform reports it.

Failure paths tear the deployment down exactly once (queue timeout, error events, unhealthy node), so a failed provision never leaves a billable deployment behind.

## Lifecycle: hourly GPU jobs, honestly

Credit-paid Nosana jobs run in hour blocks. Instead of pretending otherwise, the platform treats the hour as a first-class lifecycle:

- **In use → renewed in place.** An agent with recent activity gets its job extended (+3600s through the deployments API) before the hour lapses: the **same on-chain job id**, the same node, no cold start, mid-conversation. Extensions honor idempotency keys: replaying the same key returns the original on-chain transaction with no double charge (verified live).
- **Idle → honest stop.** When a job reaches its timeout, the deployment flips `STOPPED` on-chain. The platform detects it (a reconciler sweep plus an instant probe whenever a chat can't reach the gateway) and shows *GPU stopped*, never a dead "Live" badge.
- **Stopped → wake on demand.** A dashboard button, or simply messaging the agent (web or Telegram), restarts the GPU through one guarded transition: racing wake attempts can never launch two deployments. Scheduled tasks wake their agent too, with a bounded retry while it boots.
- **Stable addressing.** Every deployment gets a per-deployment domain at create time that survives job rotation and extensions; the per-job derived URL remains as a fallback.
- **Hourly economics.** Nosana reserves the full hour up front and refunds pro-rata to the second when a job stops early. The tooling and the engine both encode this.

## The image

Built from [`NousResearch/hermes-agent`](https://github.com/NousResearch/hermes-agent) (MIT) on top of `ollama/ollama`, installed with `uv sync` against the upstream lockfile for reproducible builds.

```bash
docker build -t voight-gpu-agent image/
# with model weights baked into a layer (turns the pull-at-boot into node-local cache):
docker build --build-arg BAKE_MODEL=hermes3:8b -t voight-gpu-agent:hermes3-8b image/
```

### Model

**Hermes 3 8B** (NousResearch's Llama 3.1 8B fine-tune, trained on the Hermes runtime's function-calling format) served by Ollama at a **64K context window**. Two sizing choices make that fit a 12GB NVIDIA 3060:

| Setting | Why |
| --- | --- |
| `OLLAMA_CONTEXT_LENGTH=65536` | The Hermes runtime requires a ≥64K window for reliable tool use; Hermes 3 supports 128K natively |
| `OLLAMA_FLASH_ATTENTION=1` + `OLLAMA_KV_CACHE_TYPE=q8_0` | A 64K KV cache on an 8B model is ~8.6GB in f16 — an 8-bit cache roughly halves it so weights + cache fit comfortably |
| Reasoning disabled in the generated config | The model is not a reasoning model; without this the runtime asks the endpoint to "think" and gets a 400 |

### Environment contract

| Variable | Role |
| --- | --- |
| `API_SERVER_KEY` | **Required.** Auth for the Hermes gateway — the service URL is publicly reachable. Keys under 16 chars are rejected by the runtime. |
| `MODEL` | Model tag Ollama serves (default `hermes3:8b`). |
| `SOUL_B64` | Agent persona (`SOUL.md`), base64. Decoded to a file, never shell-interpolated. |
| `HERMES_CONFIG_B64` | Full `config.yaml` override, base64. Omit for the built-in local-model config. |
| `VOIGHT_MEMORY_URL` | Memory sync endpoint. Unset = sync disabled. |
| `VOIGHT_AGENT_KEY` | Bearer token for the memory endpoint (per-agent, revocable). |
| `TAVILY_API_KEY` | Optional: switches web search from ddgs to Tavily. |

### Boot sequence

`start.sh` runs, in order: restore curated memory (best-effort) → materialize `config.yaml` + `SOUL.md` → start Ollama on loopback → ensure the model is present (a no-op when weights are baked) → start the Hermes gateway on :8642 → periodic memory push, with a final push on shutdown. The first process to exit takes the container down cleanly.

### Memory across job rotations

GPU jobs are ephemeral: when a job ends, its filesystem dies. The image round-trips the agent's curated memory through a platform endpoint — **restore at boot**, **checksum-gated push** on an interval and again at shutdown. The endpoint writes the same per-agent storage layout the managed-cloud host mounts, so an agent's memory is portable across hosts. A brand-new agent restoring nothing is not an error, and a failed push never takes the agent down.

## Security model

- **No inference key exists in the container.** The model is local to the GPU.
- The gateway (`:8642`) is the only exposed port and requires `API_SERVER_KEY`; Ollama binds to loopback and is never listed in the job definition's `expose`.
- Gateway and memory keys are **derived per agent** (domain-separated HMACs) — a key lifted from one container never opens another agent's gateway or memory.
- Deployments created through the Nosana API keep the filled job definition private (not pinned to public IPFS). The executing node operator can still inspect the container: treat agent memory as visible to the host, and keep secrets scoped and revocable.

## Measured performance

All numbers from live runs on the NVIDIA 3060 market ($0.048/h):

| Path | Measured |
| --- | --- |
| Create → live HTTPS service (small image) | **~20s** |
| Create → healthy agent gateway (this image, warm node) | **~77s** |
| Create → healthy gateway including the 4.7GB model pull (Hermes 3) | **~2 min** |
| Create → first LLM completion (model pulled at boot) | **~2.5-3 min** |
| Generation speed once warm | **~39 tokens/s** |
| Extend a running job +3600s (same job id, no cold start) | **$0.044**, on-chain tx; idempotent replay returns the original tx |
| Early stop | pro-rata refund to the second |

Contract details the tooling encodes: credit-paid jobs require a timeout of **at least 3600s**; job-level failures surface only in the deployment **events feed** while the deployment status stays `RUNNING`; archive requires a fully-reached `STOPPED`.

## Proven live in production

First user-created GPU agent through the production dashboard — one click, no CLI, every artifact independently verifiable:

| Artifact | Reference |
| --- | --- |
| On-chain job | [`56R81gzb…ak8Lu`](https://dashboard.nosana.com/jobs/56R81gzbmSxxxp28CzE8aqWhP7oFjfL7foj9v2pak8Lu) — NVIDIA 3060 market |
| The agent answering from the GPU | *"I'm a helpful assistant running on the Nosana decentralized GPU network."* — job [`2a2Ndy89…L8Jwr`](https://dashboard.nosana.com/jobs/2a2Ndy89UDC8EdGKUizpEb8B7eAqQCuBGUpsgd4L8Jwr) |
| Tool use inside the GPU container | The agent executed a terminal command and returned its exact output — job [`EWwYnNWT…VQCqm`](https://dashboard.nosana.com/jobs/EWwYnNWTibyTz1gP3cxUPohunmeyBGCHZWMUWDgVQCqm) |
| Same-job hourly extend, on-chain | [+3600s transaction](https://solscan.io/tx/26jdPtwTLEWePwAVVE44P3KXirmZgvonXtE72MDiv7dh4brwJ5SXkPKQNQmUweh4AWaxn2L3V82e4YqJ6uFFzWXg) on job [`8Hdnthvd…1LTqq`](https://dashboard.nosana.com/jobs/8HdnthvDzR5m3WWLhduHRdp37UHFFnNx4eF1B8T1LTqq) : replaying its idempotency key returned this same tx |
| Image digest | [`seenfinity/voight-gpu-agent`](https://hub.docker.com/r/seenfinity/voight-gpu-agent)`@sha256:7730dcb0` |

Full build log with every timing and hardening step: [PROGRESS.md](PROGRESS.md).

## Deploy CLI

Standalone tooling over the Nosana deployments API — the same lifecycle the platform engine drives, usable against any job definition:

```bash
npm install
export NOSANA_API_KEY="nos_..."   # dashboard → Account → API key

node scripts/deploy.mjs balance                # credits
node scripts/deploy.mjs markets                # GPU markets + USD/hour
node scripts/deploy.mjs up --market <addr>     # tiny web service, timed end to end
node scripts/deploy.mjs up --def my.json       # any job definition
node scripts/deploy.mjs model --market <addr>  # Ollama + model, timed to first completion
node scripts/deploy.mjs status <deploymentId>  # status, jobs, events
node scripts/deploy.mjs down <deploymentId>    # stop, verify STOPPED, then archive
```

## Model readiness

Not every small model can drive an agent. `model-check` validates the three behaviors the runtime depends on, against any OpenAI-compatible endpoint:

```bash
node scripts/model-check.mjs --base https://<service-url> --model hermes3:8b
```

1. Plain completions return non-empty `content` (reasoning models can starve it),
2. tool calls arrive as well-formed `tool_calls` with parseable JSON arguments,
3. a tool-result follow-up turn produces a grounded final answer.

## Repository layout

| Path | What |
| --- | --- |
| [`image/`](image/) | The agent container: Dockerfile, boot sequence, memory sync |
| [`job/`](job/) | Job definition template the deploy engine fills and validates |
| [`scripts/deploy.mjs`](scripts/deploy.mjs) | CLI over the Nosana deployments API |
| [`scripts/model-check.mjs`](scripts/model-check.mjs) | Agent-readiness check for GPU-hosted models |
| [`PROGRESS.md`](PROGRESS.md) | Chronological build log with verifiable artifacts |

## License

MIT © [Galaxyhub Labs Inc.](https://voight.xyz) d/b/a Voight
