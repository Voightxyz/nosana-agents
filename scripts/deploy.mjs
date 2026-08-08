#!/usr/bin/env node
// Deployment CLI over the Nosana deployments API — create, probe, and tear down
// GPU deployments end to end (service URL + health + first-completion timing).
// Usage:
//   NOSANA_API_KEY=nos_xxx node scripts/deploy.mjs balance
//   NOSANA_API_KEY=nos_xxx node scripts/deploy.mjs markets
//   NOSANA_API_KEY=nos_xxx node scripts/deploy.mjs up      --market <addr> [--timeout 60]
//   NOSANA_API_KEY=nos_xxx node scripts/deploy.mjs model   --market <addr> [--timeout 60] [--model qwen3:8b]
//   NOSANA_API_KEY=nos_xxx node scripts/deploy.mjs status <deploymentId>
//   NOSANA_API_KEY=nos_xxx node scripts/deploy.mjs down   <deploymentId>
// Notes: credit-paid jobs require a timeout of at least 3600 seconds (60 min),
// and archiving requires the deployment to have fully reached STOPPED first.
import { createNosanaClient, getJobExposedServices } from '@nosana/kit';

const API_KEY = process.env.NOSANA_API_KEY;
if (!API_KEY) { console.error('Missing NOSANA_API_KEY'); process.exit(1); }

const [cmd, ...rest] = process.argv.slice(2);
const flags = {};
const positional = [];
for (let i = 0; i < rest.length; i++) {
  if (rest[i].startsWith('--')) { flags[rest[i].slice(2)] = rest[i + 1]; i++; }
  else positional.push(rest[i]);
}

const client = createNosanaClient('mainnet', { api: { apiKey: API_KEY } });
const NODE_DOMAIN = 'node.k8s.prd.nos.ci';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const now = () => Date.now();
const secs = (t0) => ((now() - t0) / 1000).toFixed(1) + 's';

function serviceUrls(jobDefinition, jobId) {
  try {
    return getJobExposedServices(jobDefinition, jobId).map((s) => `https://${s.hash}.${NODE_DOMAIN}`);
  } catch { return []; }
}

function jobsOf(res) {
  const list = Array.isArray(res) ? res : res?.jobs ?? res?.data ?? [];
  return list.map((j) => (typeof j === 'string' ? j : j.job ?? j.id ?? j.address)).filter(Boolean);
}

async function pollUntil(label, fn, { every = 5000, max = 900000 } = {}) {
  const t0 = now();
  for (;;) {
    const out = await fn().catch(() => null);
    if (out) { console.log(`  ✔ ${label} in ${secs(t0)}`); return { out, ms: now() - t0 }; }
    if (now() - t0 > max) throw new Error(`timed out waiting for: ${label}`);
    await sleep(every);
  }
}

const BASIC_DEF = {
  version: '0.1',
  type: 'container',
  meta: { trigger: 'api' },
  ops: [{
    type: 'container/run',
    id: 'web',
    args: {
      image: 'docker.io/hashicorp/http-echo:latest',
      cmd: ['-listen=:8080', '-text=voight-spike-ok'],
      expose: [{ port: 8080, health_checks: [{ type: 'http', path: '/', method: 'GET', expected_status: 200, continuous: true }] }],
    },
  }],
};

function modelDef(model) {
  return {
    version: '0.1',
    type: 'container',
    meta: { trigger: 'api', system_requirements: { required_vram: 8 } },
    ops: [{
      type: 'container/run',
      id: 'ollama',
      args: {
        image: 'docker.io/ollama/ollama:latest',
        gpu: true,
        entrypoint: ['/bin/sh'],
        cmd: ['-c', `ollama serve & sleep 5 && ollama pull ${model} && wait`],
        expose: [{ port: 11434, health_checks: [{ type: 'http', path: '/api/tags', method: 'GET', expected_status: 200, continuous: true }] }],
      },
    }],
  };
}

async function up({ def, name, timeout, market }) {
  if (!market) { console.error('Missing --market <addr> (run `node scripts/deploy.mjs markets`)'); process.exit(1); }
  console.log(`Creating deployment "${name}" on market ${market}, timeout ${timeout}min…`);
  const t0 = now();
  const dep = await client.api.deployments.create({
    name, market, timeout: Number(timeout), replicas: 1, strategy: 'SIMPLE', job_definition: def,
  });
  console.log(`  ✔ created: ${dep.id} (status ${dep.status}) in ${secs(t0)}`);

  await dep.start();
  console.log(`  ✔ start accepted in ${secs(t0)}`);

  let jobId = null;
  await pollUntil('deployment RUNNING with job assigned', async () => {
    const cur = await client.api.deployments.get(dep.id);
    const jobs = jobsOf(await cur.getJobs().catch(() => []));
    if (jobs.length) jobId = jobs[0];
    return cur.status === 'RUNNING' && jobs.length ? cur : null;
  });

  const urls = serviceUrls(def, jobId);
  console.log(`  job: ${jobId}`);
  console.log(`  per-job URLs: ${urls.join(' ')}`);

  for (const url of urls) {
    await pollUntil(`HTTP 200 at ${url} (end-to-end cold start)`, async () => {
      const r = await fetch(url, { signal: AbortSignal.timeout(8000) }).catch(() => null);
      return r && r.ok ? r : null;
    });
  }
  console.log(`\nTOTAL create→live service: ${secs(t0)}`);
  console.log(`Tear down: node scripts/deploy.mjs down ${dep.id}`);
  return { id: dep.id, jobId, urls, t0 };
}

switch (cmd) {
  case 'balance': {
    console.log(JSON.stringify(await client.api.credits.balance(), null, 2));
    break;
  }
  case 'markets': {
    const list = await client.api.markets.list();
    const rows = (Array.isArray(list) ? list : list.markets ?? []).map((m) => ({
      address: m.address ?? m.id, name: m.name ?? m.slug, price: m.usd_price ?? m.price ?? m.usdPrice,
      vram: m.vram ?? m.gpu_memory, gpus: m.gpu_types ?? m.gpus ?? m.type,
    }));
    console.table(rows);
    break;
  }
  case 'up': {
    await up({ def: BASIC_DEF, name: 'voight-agent-demo-web', timeout: flags.timeout ?? 60, market: flags.market });
    break;
  }
  case 'model': {
    const model = flags.model ?? 'qwen3:8b';
    const r = await up({ def: modelDef(model), name: 'voight-agent-demo-model', timeout: flags.timeout ?? 60, market: flags.market });
    const base = r.urls[0];
    await pollUntil(`model ${model} answers a completion (pull + load)`, async () => {
      const res = await fetch(`${base}/v1/chat/completions`, {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ model, messages: [{ role: 'user', content: 'Reply with exactly: ok' }], max_tokens: 10 }),
        signal: AbortSignal.timeout(30000),
      }).catch(() => null);
      if (!res || !res.ok) return null;
      const body = await res.json();
      console.log('  response:', JSON.stringify(body.choices?.[0]?.message));
      return body;
    }, { every: 10000, max: 1500000 });
    console.log(`\nTOTAL create→first completion: ${secs(r.t0)}`);
    console.log(`Tear down: node scripts/deploy.mjs down ${r.id}`);
    break;
  }
  case 'status': {
    const dep = await client.api.deployments.get(positional[0]);
    const { start, stop, archive, ...plain } = dep;
    console.log(JSON.stringify(plain, (k, v) => (typeof v === 'function' ? undefined : v), 2));
    const jobs = jobsOf(await dep.getJobs().catch(() => []));
    console.log('jobs:', jobs);
    const events = await dep.getEvents({ limit: 10 }).catch(() => null);
    if (events) console.log('events:', JSON.stringify(events, null, 2));
    break;
  }
  case 'down': {
    const dep = await client.api.deployments.get(positional[0]);
    await dep.stop().catch((e) => console.log('stop:', e.message));
    console.log('  ✔ stop sent');
    await sleep(3000);
    await dep.archive().catch((e) => console.log('archive:', e.message));
    console.log('  ✔ archived');
    break;
  }
  default:
    console.log('Commands: balance | markets | up | model | status <id> | down <id>');
}
