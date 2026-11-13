// Gemini quota / proxy diagnosis. Prints no secrets.
//
//   node backend/diagnose.mjs direct   (needs GEMINI_API_KEY in the environment)
//       Calls every model in wrangler.toml once with the follow-up prompt
//       and reports status, quota id (per-minute vs per-day), retry delay and tokens used.
//   node backend/diagnose.mjs proxy    (reads env.json: CATALYST_API_URL, CATALYST_API_TOKEN)
//       Calls the deployed Worker; with the updated worker a 502 lists per-model attempts.
import { readFileSync } from 'node:fs';
import { loadWorker, readModels } from './load-worker.mjs';

const mode = process.argv[2];
const worker = await loadWorker();
const sampleArticles = [
  { law: 'CivilCode', article: '1654', text: 'The lessor is obliged to deliver the thing which is the object of the contract.' },
  { law: 'CivilCode', article: '1673', text: 'The lessor may judicially eject the lessee for expiration of the period or non-payment of rent.' },
  { law: 'ConsumerAct', article: '100', text: 'Prohibited acts in relation to deceptive sales acts and practices.' },
];
const sampleQuery = 'My landlord evicted us before our lease had ended.';
const sample = { mode: 'followup', query: 'Which provisions should I check?', narrative: sampleQuery, articles: sampleArticles, cases: [], languages: ['en'] };

if (mode === 'direct') {
  const key = process.env.GEMINI_API_KEY;
  if (!key) throw new Error('Set GEMINI_API_KEY in the environment first.');
  for (const model of readModels()) {
    const started = Date.now();
    const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-goog-api-key': key },
      body: JSON.stringify({
        contents: [{ role: 'user', parts: [{ text: worker.buildFollowupPrompt(sample, 'en') }] }],
        generationConfig: { temperature: 0.3, maxOutputTokens: 4096, responseMimeType: 'application/json' },
      }),
    });
    const text = await res.text();
    const ms = Date.now() - started;
    if (!res.ok) {
      console.log(model, ms + 'ms', JSON.stringify(worker.summarizeUpstreamError(res.status, text)));
      continue;
    }
    const data = JSON.parse(text);
    const out = (data.candidates?.[0]?.content?.parts || []).map((p) => p.text || '').join('');
    let answer = 'unparseable';
    try {
      answer = worker.parseFollowupJson(out, []).answer;
    } catch {}
    console.log(model, ms + 'ms', 'OK', JSON.stringify(data.usageMetadata || {}), 'answer=' + answer);
  }
} else if (mode === 'proxy') {
  const env = JSON.parse(readFileSync(new URL('../env.json', import.meta.url), 'utf8'));
  const started = Date.now();
  const res = await fetch(env.CATALYST_API_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-catalyst-token': env.CATALYST_API_TOKEN },
    body: JSON.stringify(sample),
  });
  const text = await res.text();
  console.log('proxy', res.status, Date.now() - started + 'ms', text.slice(0, 600));
  if (res.status === 401) console.log('401: CATALYST_API_TOKEN in env.json does not match the deployed APP_TOKEN secret.');
} else {
  console.log('usage: node backend/diagnose.mjs direct|proxy');
}
