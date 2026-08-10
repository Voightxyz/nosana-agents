#!/usr/bin/env node
// Model capability check for a GPU-hosted OpenAI-compatible endpoint (Ollama).
// Validates the three things an agent runtime needs from a local model:
//   1. plain completions return non-empty content (reasoning models can starve
//      `content` when the thinking budget eats max_tokens),
//   2. tool calling emits well-formed tool_calls with parseable JSON arguments,
//   3. a tool-result follow-up turn produces a grounded final answer.
// Usage:
//   node scripts/model-check.mjs --base https://<service-url> [--model llama3.1:8b]
const flags = {};
const rest = process.argv.slice(2);
for (let i = 0; i < rest.length; i++) {
  if (rest[i].startsWith('--')) { flags[rest[i].slice(2)] = rest[i + 1]; i++; }
}
const BASE = flags.base?.replace(/\/$/, '');
const MODEL = flags.model ?? 'llama3.1:8b';
if (!BASE) { console.error('Missing --base <service-url>'); process.exit(1); }

const results = [];
function verdict(name, pass, detail) {
  results.push({ name, pass });
  console.log(`${pass ? '✔' : '✘'} ${name}${detail ? ` — ${detail}` : ''}`);
}

async function chat(body, path = '/v1/chat/completions') {
  const res = await fetch(`${BASE}${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(180000),
  });
  if (!res.ok) throw new Error(`${path} → HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`);
  return res.json();
}

const WEATHER_TOOL = {
  type: 'function',
  function: {
    name: 'get_weather',
    description: 'Get the current weather for a city',
    parameters: {
      type: 'object',
      properties: { city: { type: 'string', description: 'City name' } },
      required: ['city'],
    },
  },
};

// ── 1. server + model present ─────────────────────────────────────────────
const tags = await fetch(`${BASE}/api/tags`, { signal: AbortSignal.timeout(15000) }).then((r) => r.json());
const models = (tags.models ?? []).map((m) => m.name);
verdict('server up, model present', models.some((m) => m.startsWith(MODEL.split(':')[0])), `models: ${models.join(', ') || 'none'}`);

// ── 2. plain completion yields non-empty content ──────────────────────────
const plain = await chat({
  model: MODEL,
  messages: [{ role: 'user', content: 'In one short sentence: what is Solana?' }],
  max_tokens: 600,
});
const pmsg = plain.choices?.[0]?.message ?? {};
verdict(
  'plain completion has content',
  typeof pmsg.content === 'string' && pmsg.content.trim().length > 0,
  `content: ${JSON.stringify((pmsg.content ?? '').slice(0, 80))}${'reasoning' in pmsg ? ' (reasoning field present)' : ''}`,
);

// ── 3. tool calling emits well-formed tool_calls ──────────────────────────
const toolTurn = await chat({
  model: MODEL,
  messages: [{ role: 'user', content: 'What is the weather in Madrid right now? Use the tool.' }],
  tools: [WEATHER_TOOL],
  max_tokens: 600,
});
const tmsg = toolTurn.choices?.[0]?.message ?? {};
const call = tmsg.tool_calls?.[0];
let argsOk = false;
let cityArg = null;
try { cityArg = JSON.parse(call?.function?.arguments ?? '{}').city; argsOk = typeof cityArg === 'string' && cityArg.length > 0; } catch {}
verdict(
  'tool call emitted with parseable arguments',
  call?.function?.name === 'get_weather' && argsOk,
  call ? `${call.function?.name}(${call.function?.arguments})` : `no tool_calls; content: ${JSON.stringify((tmsg.content ?? '').slice(0, 80))}`,
);

// ── 4. tool-result follow-up produces a grounded answer ───────────────────
if (call) {
  const followUp = await chat({
    model: MODEL,
    messages: [
      { role: 'user', content: 'What is the weather in Madrid right now? Use the tool.' },
      { role: 'assistant', content: tmsg.content ?? '', tool_calls: tmsg.tool_calls },
      { role: 'tool', tool_call_id: call.id ?? 'call_0', content: '{"temp_c": 31, "condition": "sunny"}' },
    ],
    tools: [WEATHER_TOOL],
    max_tokens: 600,
  });
  const fmsg = followUp.choices?.[0]?.message ?? {};
  const grounded = typeof fmsg.content === 'string' && /31|sunny|soleado/i.test(fmsg.content);
  verdict('tool-result follow-up is grounded', grounded, `content: ${JSON.stringify((fmsg.content ?? '').slice(0, 100))}`);
} else {
  verdict('tool-result follow-up is grounded', false, 'skipped: no tool call to follow up');
}

// ── summary ───────────────────────────────────────────────────────────────
const passed = results.filter((r) => r.pass).length;
console.log(`\n${passed}/${results.length} checks passed → ${passed === results.length ? 'MODEL IS AGENT-READY' : 'NOT READY'}`);
process.exit(passed === results.length ? 0 : 1);
