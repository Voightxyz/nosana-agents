# Voight Nosana Agents

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![Runtime](https://img.shields.io/badge/runtime-Hermes-blue.svg)
![Inference](https://img.shields.io/badge/inference-local%20GPU-brightgreen.svg)

**Run autonomous AI agents on [Nosana](https://nosana.com) decentralized GPUs, with the model living inside the container.**

This repository holds the container image and deployment tooling behind [Voight](https://voight.xyz)'s GPU-hosted agents: one Nosana job = one agent with its own dedicated GPU, its own local model, and zero inference credentials to leak.

```
┌─────────────────────────── Nosana GPU job ───────────────────────────┐
│                                                                      │
│   Ollama (127.0.0.1:11434)  ◄──  Hermes agent runtime                │
│   local model, loopback only     gateway on :8642 (the ONLY          │
│                                  exposed port, key-protected)        │
│                                                                      │
│   memory-sync: restore at boot ── push on interval + shutdown        │
└──────────────────────────────────────────────────────────────────────┘
         ▲                                        │
   deploy engine                        https://<hash>.node.k8s.prd.nos.ci
   (Nosana deployments API)                (verifiable on-chain job)
```

## Why a local model

Agents on decentralized compute have a credential problem: anything you put in a container can be inspected by the node operator running it. Shipping an inference API key means trusting every node with your token spend. This image dissolves the problem instead of mitigating it: the model runs **inside the job, on the job's own GPU**, so there is no inference key at all. What remains in the container is scoped and revocable per agent (gateway key, memory token).

Every deployment is also a real Solana account: the job, its GPU market, the node that ran it, and its timings are independently verifiable on the [Nosana dashboard](https://dashboard.nosana.com), which pairs with agents observed by the [`@voightxyz/nosana`](https://github.com/Voightxyz/Nosana-SDK) SDK.

## Repository layout

| Path | What |
| --- | --- |
| [`image/`](image/) | The agent container: Dockerfile, boot sequence, memory sync |
| [`job/`](job/) | Nosana job definition template the deploy engine fills and validates |
| [`scripts/deploy.mjs`](scripts/deploy.mjs) | CLI over the Nosana deployments API (create / probe / tear down) |
| [`scripts/model-check.mjs`](scripts/model-check.mjs) | Validates a GPU-hosted model is agent-ready (tool calling) |

## The image

Built from [`NousResearch/hermes-agent`](https://github.com/NousResearch/hermes-agent) (MIT) on top of `ollama/ollama`:

```bash
docker build -t voight-gpu-agent image/
# with model weights baked into a layer (skips the pull at boot):
docker build --build-arg BAKE_MODEL=llama3.1:8b -t voight-gpu-agent:llama3.1-8b image/
```

### Environment contract

| Variable | Role |
| --- | --- |
| `API_SERVER_KEY` | **Required.** Auth for the Hermes gateway: the service URL is public. |
| `MODEL` | Model tag Ollama serves (default `llama3.1:8b`). |
| `SOUL_B64` | Agent persona (`SOUL.md`), base64. Decoded to a file, never shell-interpolated. |
| `HERMES_CONFIG_B64` | Full `config.yaml` override, base64. Omit for the built-in local-model config. |
| `VOIGHT_MEMORY_URL` | Memory sync endpoint. Unset = sync disabled. |
| `VOIGHT_AGENT_KEY` | Bearer token for the memory endpoint (per-agent, revocable). |
| `TAVILY_API_KEY` | Optional: switches web search from ddgs to Tavily. |

### Memory across job rotations

GPU jobs are ephemeral: when a job ends, its filesystem dies. The image round-trips the agent's curated memory through a platform endpoint: **restore at boot**, **checksum-gated push** on an interval and again at shutdown. A brand-new agent restoring nothing is not an error, and a failed push never takes the agent down.

### Security model

- **No inference key exists in the container.** The model is local.
- The gateway (`:8642`) is the only exposed port and requires `API_SERVER_KEY`; Ollama binds to loopback and is never listed in the job definition's `expose`.
- Deployments created through the Nosana API keep the filled job definition private (it is not pinned to public IPFS). The executing node operator can still inspect the container: treat agent memory as visible to the host, and keep secrets scoped and revocable.

## Deploy CLI

```bash
npm install
export NOSANA_API_KEY="nos_..."   # dashboard → Account → API key

node scripts/deploy.mjs balance                # credits
node scripts/deploy.mjs markets                # GPU markets + USD/hour
node scripts/deploy.mjs up --market <addr>     # tiny web service, timed end to end
node scripts/deploy.mjs model --market <addr>  # Ollama + model, timed to first completion
node scripts/deploy.mjs status <deploymentId>  # status, jobs, events
node scripts/deploy.mjs down <deploymentId>    # stop, then archive once STOPPED
```

Measured on the NVIDIA 3060 market ($0.048/h): a plain web service goes **create → live HTTPS in ~20s**; Ollama pulling `llama3.1:8b` at boot reaches **first completion in ~3 minutes** (~39 tokens/s once warm). Two contract details the CLI already encodes: credit-paid jobs need a timeout of **at least 3600 seconds**, and archiving requires the deployment to have fully reached `STOPPED`.

## Model readiness

Not every small model can drive an agent. `model-check` validates the three behaviors the runtime depends on, against any OpenAI-compatible endpoint:

```bash
node scripts/model-check.mjs --base https://<service-url> --model llama3.1:8b
```

1. Plain completions return non-empty `content` (reasoning models can starve it),
2. tool calls arrive as well-formed `tool_calls` with parseable JSON arguments,
3. a tool-result follow-up turn produces a grounded final answer.

## License

MIT © [Galaxyhub Labs Inc.](https://voight.xyz) d/b/a Voight
