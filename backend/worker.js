// CATALYST proxy: keeps the Gemini API key off the phone.
// Deploy: see README.md in this folder.
//
// POST / { mode: 'followup', query, narrative, articles, cases, languages }
// -> { answer, citedCaseIds, sources, searched }

const MAX_QUERY = 2000;
const LANGUAGES = { en: 'plain English', tl: 'plain Filipino (Tagalog)', taglish: 'natural Taglish (Tagalog mixed with common English words, as Filipinos speak)' };

// Reduces a Gemini error body to non-sensitive fields: status, quota metric and retry delay.
export function summarizeUpstreamError(status, text) {
  const out = { status };
  try {
    const err = JSON.parse(text).error || {};
    if (err.status) out.code = err.status;
    for (const d of err.details || []) {
      for (const v of d.violations || []) {
        out.quota = out.quota || { metric: v.quotaMetric, id: v.quotaId, model: (v.quotaDimensions || {}).model };
      }
      if (d.retryDelay) out.retryDelay = d.retryDelay;
    }
    if (!out.quota && err.message) out.message = String(err.message).slice(0, 160);
  } catch {
    out.message = String(text).slice(0, 120);
  }
  return out;
}

export function normalizeModel(value) {
  const m = String(value || '').trim().replace(/^models\//, '');
  return /^[A-Za-z0-9._-]+$/.test(m) ? m : 'gemini-3.8-flash';
}

export function validate(body) {
  if (!body || typeof body.query !== 'string') return 'query is required';
  const query = body.query.trim();
  if (!query || query.length > MAX_QUERY) return 'query length is invalid';
  return null;
}

const json = (data, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { 'content-type': 'application/json' },
  });

export function buildFollowupPrompt(body, language) {
  const clip = (v, n) => String(v || '').replace(/\s+/g, ' ').trim().slice(0, n);
  const articles = (Array.isArray(body.articles) ? body.articles : []).slice(0, 8)
    .map((a, i) => `${i + 1}. ${clip(a.law, 40)} Article ${clip(a.article, 20)}: ${clip(a.text, 420)}`)
    .join('\n');
  const cases = (Array.isArray(body.cases) ? body.cases : []).slice(0, 5)
    .map((c, i) => `[${clip(c.id, 80)}] ${clip(c.citation, 200)}\n  Holding/lead: ${clip(c.holding, 450)}\n  Disposition: ${clip(c.dispositive, 300)}\n  Passages: ${(Array.isArray(c.passages) ? c.passages : []).slice(0, 2).map((p) => clip(p, 420)).join(' | ')}`)
    .join('\n');
  const history = clip(body.narrative, 1200);
  return `You are a legal information assistant for Philippine law inside a research app. Answer the user's follow-up question in ${LANGUAGES[language] || LANGUAGES.en}, in plain words an ordinary person understands.

User's situation: """${history}"""
Follow-up question: """${clip(body.query, 600)}"""

Statute provisions already retrieved from the app's corpus:
${articles || '(none)'}

Supreme Court decisions from the app's jurisprudence dataset:
${cases || '(none)'}

Rules:
- Ground the answer ONLY in the provisions and decisions listed above. Never invent a case, a G.R. number, a quote or an article.
- When you rely on a decision, name it exactly as listed (title and G.R. No.) and say in one plain sentence what the Court decided and how it relates to the user's facts. Put its id in "citedCaseIds".
- If none of the listed decisions addresses the question, say so plainly instead of stretching a decision to fit.
- Keep it under 170 words. Use short paragraphs or "-" bullets. No legal conclusion about who wins; say what depends on the facts.
${body.useSearch ? '- You may also use web search for related Philippine Supreme Court rulings, but put anything from the web in a final paragraph that starts with "Online (not verified in the corpus):".' : ''}
- Output ONLY JSON: {"answer":"...","citedCaseIds":["id"]}`;
}

export function parseFollowupJson(text, allowedIds) {
  const cleaned = String(text).replace(/```json|```/gi, '').trim();
  const start = cleaned.indexOf('{');
  const end = cleaned.lastIndexOf('}');
  if (start < 0 || end <= start) throw new Error('no JSON in model output');
  const parsed = JSON.parse(cleaned.slice(start, end + 1));
  const answer = String(parsed.answer || '').trim().slice(0, 1800);
  if (!answer) throw new Error('empty answer');
  const ids = (Array.isArray(parsed.citedCaseIds) ? parsed.citedCaseIds : [])
    .map(String)
    .filter((id) => allowedIds.includes(id))
    .slice(0, 5);
  return { answer, citedCaseIds: ids };
}

async function handleFollowup(body, env) {
  const language = LANGUAGES[(body.languages || [])[0]] ? body.languages[0] : 'en';
  const allowedIds = (Array.isArray(body.cases) ? body.cases : []).map((c) => String(c.id || ''));
  const models = String(env.GEMINI_MODEL || '')
    .split(',')
    .map(normalizeModel)
    .filter((m, i, a) => a.indexOf(m) === i);
  const wantSearch = env.FOLLOWUP_SEARCH === 'true';
  // Grounded search is tried once first; it is quota-limited, so plain grounding in the corpus is the fallback.
  const attempts = [
    ...(wantSearch ? [{ model: models[0], grounded: true }] : []),
    ...models.map((model) => ({ model, grounded: false })),
  ];
  const failures = [];
  for (const { model, grounded } of attempts) {
    try {
      const prompt = buildFollowupPrompt({ ...body, useSearch: grounded }, language);
      const res = await fetch(
        `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`,
        {
          signal: AbortSignal.timeout(16000),
          method: 'POST',
          headers: { 'content-type': 'application/json', 'x-goog-api-key': env.GEMINI_API_KEY },
          body: JSON.stringify({
            contents: [{ role: 'user', parts: [{ text: prompt }] }],
            ...(grounded ? { tools: [{ google_search: {} }] } : {}),
            generationConfig: {
              temperature: 0.3,
              maxOutputTokens: 4096,
              ...(grounded ? {} : { responseMimeType: 'application/json' }),
            },
          }),
        },
      );
      if (!res.ok) {
        const errorText = (await res.text()).slice(0, 2000);
        failures.push({ model, grounded, ...summarizeUpstreamError(res.status, errorText) });
        console.error('Gemini followup failed', { model, grounded, status: res.status, error: errorText.slice(0, 300) });
        continue;
      }
      const data = await res.json();
      const candidate = data.candidates && data.candidates[0];
      const text = ((candidate && candidate.content && candidate.content.parts) || []).map((p) => p.text || '').join('');
      const { answer, citedCaseIds } = parseFollowupJson(text, allowedIds);
      const chunks = (candidate && candidate.groundingMetadata && candidate.groundingMetadata.groundingChunks) || [];
      const sources = chunks
        .map((c) => c.web && c.web.title)
        .filter(Boolean)
        .slice(0, 4)
        .map((title) => ({ title }));
      return json({ answer, citedCaseIds, sources, searched: grounded && sources.length > 0 });
    } catch (err) {
      failures.push({ model, grounded, status: 0, message: (err && err.name) || 'error' });
      console.error('Gemini followup error', { model, grounded, name: err && err.name });
    }
  }
  return json({ error: 'upstream error', attempts: failures }, 502);
}

export default {
  async fetch(request, env) {
    if (request.method !== 'POST') return json({ error: 'POST only' }, 405);
    if (env.APP_TOKEN && request.headers.get('x-catalyst-token') !== env.APP_TOKEN) {
      return json({ error: 'unauthorized' }, 401);
    }
    let body;
    try {
      body = await request.json();
    } catch {
      return json({ error: 'invalid JSON' }, 400);
    }
    if (!body || body.mode !== 'followup') {
      return json({ error: 'only follow-up requests are supported' }, 400);
    }
    const problem = validate(body);
    if (problem) return json({ error: problem }, 400);
    return handleFollowup(body, env);
  },
};
