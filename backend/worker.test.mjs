// Run: node --test backend/worker.test.mjs   (no API key or network needed)
import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';
import { loadWorker } from './load-worker.mjs';

const worker = await loadWorker();
const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

const quotaBody = JSON.stringify({
  error: {
    code: 429,
    status: 'RESOURCE_EXHAUSTED',
    message: 'You exceeded your current quota',
    details: [
      {
        '@type': 'type.googleapis.com/google.rpc.QuotaFailure',
        violations: [
          {
            quotaMetric: 'generativelanguage.googleapis.com/generate_content_free_tier_requests',
            quotaId: 'GenerateRequestsPerDayPerProjectPerModel-FreeTier',
            quotaDimensions: { model: 'gemini-3.5-flash-lite' },
          },
        ],
      },
      { '@type': 'type.googleapis.com/google.rpc.RetryInfo', retryDelay: '31s' },
    ],
  },
});

const env = { GEMINI_API_KEY: 'k', GEMINI_MODEL: 'm-a,m-b,m-c', APP_TOKEN: 't' };
const request = (body) =>
  new Request('https://proxy.test/', {
    method: 'POST',
    headers: { 'x-catalyst-token': 't' },
    body: JSON.stringify(body),
  });
const query = { query: 'My landlord evicted me early.', candidates: [{ law: 'CivilCode', article: '1654', text: 'x' }] };

test('summarizeUpstreamError extracts the quota metric and retry delay', () => {
  const s = worker.summarizeUpstreamError(429, quotaBody);
  assert.equal(s.status, 429);
  assert.equal(s.code, 'RESOURCE_EXHAUSTED');
  assert.equal(s.quota.id, 'GenerateRequestsPerDayPerProjectPerModel-FreeTier');
  assert.equal(s.retryDelay, '31s');
});

test('article retrieval requests are rejected without contacting Gemini', async () => {
  globalThis.fetch = async () => assert.fail('must not call Gemini');
  const res = await worker.default.fetch(request(query), env);
  assert.equal(res.status, 400);
});

test('follow-up tries each model when all are over quota', async () => {
  const calls = [];
  globalThis.fetch = async (url) => {
    calls.push(String(url).match(/models\/([^:]+):/)[1]);
    return new Response(quotaBody, { status: 429 });
  };
  const res = await worker.default.fetch(request({ mode: 'followup', query: 'what if' }), env);
  assert.equal(res.status, 502);
  const body = await res.json();
  assert.deepEqual(calls, ['m-a', 'm-b', 'm-c']);
  assert.equal(body.attempts.length, 3);
  assert.equal(body.attempts[0].status, 429);
});

test('falls through an over-quota model to the next one', async () => {
  let n = 0;
  globalThis.fetch = async () => {
    if (n++ === 0) return new Response(quotaBody, { status: 429 });
    const text = JSON.stringify({ answer: 'The result depends on the facts.', citedCaseIds: [] });
    return Response.json({ candidates: [{ content: { parts: [{ text }] } }] });
  };
  const res = await worker.default.fetch(request({ mode: 'followup', query: 'what if' }), env);
  assert.equal(res.status, 200);
  assert.equal((await res.json()).answer, 'The result depends on the facts.');
  assert.equal(n, 2);
});

test('follow-up with search enabled spends up to 4 calls when quota is exhausted', async () => {
  let n = 0;
  globalThis.fetch = async () => {
    n++;
    return new Response(quotaBody, { status: 429 });
  };
  const res = await worker.default.fetch(
    request({ mode: 'followup', query: 'what if', narrative: 'n', articles: [], cases: [] }),
    { ...env, FOLLOWUP_SEARCH: 'true' },
  );
  assert.equal(res.status, 502);
  assert.equal(n, 4);
});

test('wrong token is rejected before any Gemini call', async () => {
  globalThis.fetch = async () => assert.fail('must not call Gemini');
  const res = await worker.default.fetch(
    new Request('https://proxy.test/', { method: 'POST', headers: { 'x-catalyst-token': 'bad' }, body: '{}' }),
    env,
  );
  assert.equal(res.status, 401);
});

test('follow-up only accepts supplied case IDs', () => {
  const parsed = worker.parseFollowupJson(
    '{"answer":"Details matter.","citedCaseIds":["known","unknown"]}',
    ['known'],
  );
  assert.deepEqual(parsed.citedCaseIds, ['known']);
});
