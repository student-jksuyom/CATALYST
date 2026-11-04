// CATALYST proxy: keeps the Gemini API key off the phone.
// Deploy: see README.md in this folder.
//
// POST /  { query: string, candidates: [{law, article, text}], languages?: ['en'|'tl'|'taglish'] }
// ->      { ranked: [{law, article, relevance, reason, explain?: {en: [..], tl: [..]}}], sources: [{title}] }

const MAX_QUERY = 2000;
const MAX_CANDIDATES = 60;
const MAX_TEXT = 500;
const LAWS = ['CivilCode', 'FamilyCode', 'ConsumerAct'];
const LANGUAGES = { en: 'plain English', tl: 'plain Filipino (Tagalog)', taglish: 'natural Taglish (Tagalog mixed with common English words, as Filipinos speak)' };
const EXPLAIN_TOP = 3;

export function pickLanguages(value) {
  const picked = (Array.isArray(value) ? value : []).filter((l, i, a) => LANGUAGES[l] && a.indexOf(l) === i);
  return picked.length ? picked.slice(0, 2) : ['en'];
}

export function buildPrompt(query, candidates, languages = ['en']) {
  const list = candidates
    .map((c, i) => `${i + 1}. ${c.law} Article ${c.article}: ${c.text}`)
    .join('\n');
  const explainShape = `,"explain":{${languages.map((l) => `"${l}":["bullet","bullet","bullet"]`).join(',')}}`;
  const explainRules = `- For the first ${EXPLAIN_TOP} ranked articles ONLY, add "explain": for each of these languages, ${languages.map((l) => `"${l}" = ${LANGUAGES[l]}`).join('; ')}, write exactly 3 short bullets (max 30 words each) for an ordinary person with no legal training: (1) what the article means in everyday words, WITHOUT quoting or copying its text; (2) how it connects to THIS user's specific facts, naming the facts; (3) what condition, exception or missing fact decides whether it applies. Wrap the single most important phrase of each bullet in ** **. Use only the article text given and the user's facts; never invent facts or give a final legal conclusion. Keep the same meaning in every language.`;
  return `You are a legal research assistant for Philippine law. The corpus covers only: Civil Code (RA 386) = "CivilCode", Family Code (EO 209) = "FamilyCode", Consumer Act (RA 7394) = "ConsumerAct".

The user's situation (may be Tagalog, English or Taglish):
"""${query}"""

Rerank the candidate provisions below: list every provision that applies to the user's facts or is closely related, most directly relevant first (at most 15).

Candidate provisions from the app's corpus (preferred source):
${list || '(none)'}

Rules:
- Use ONLY provisions from the candidate list. Do not add provisions that are not listed.
- "direct" = the article addresses the specific issue in the facts. "related" = same topic or a supporting rule. Mention conditions, exceptions, or missing facts in the reason.
- Do not include provisions that merely share words with the facts.
- Do not state a final legal conclusion or give legal advice. If the text is not a legal situation, return an empty list.
${explainRules}
- Output ONLY JSON, no markdown: {"ranked":[{"law":"CivilCode|FamilyCode|ConsumerAct","article":"493","relevance":"direct|related","reason":"1-2 English sentences linking the article to the facts"${explainShape}}]}`;
}

function cleanBullets(value) {
  if (!Array.isArray(value)) return [];
  return value
    .map((b) => String(b || '').trim().slice(0, 320))
    .filter(Boolean)
    .slice(0, 4)
    .map((b) => ((b.match(/\*\*/g) || []).length % 2 === 0 ? b : b.replace(/\*\*/g, '')));
}

export function parseModelJson(text) {
  const cleaned = String(text).replace(/```json|```/gi, '').trim();
  const start = cleaned.indexOf('{');
  const end = cleaned.lastIndexOf('}');
  if (start < 0 || end <= start) throw new Error('no JSON in model output');
  const parsed = JSON.parse(cleaned.slice(start, end + 1));
  const ranked = Array.isArray(parsed.ranked) ? parsed.ranked : [];
  return ranked
    .filter((r) => r && LAWS.includes(r.law) && r.article)
    .slice(0, 15)
    .map((r) => {
      const item = {
        law: r.law,
        article: String(r.article),
        relevance: r.relevance === 'direct' ? 'direct' : 'related',
        reason: String(r.reason || '').slice(0, 400),
      };
      const explain = {};
      for (const lang of Object.keys(LANGUAGES)) {
        const bullets = cleanBullets(r.explain && r.explain[lang]);
        if (bullets.length) explain[lang] = bullets;
      }
      if (Object.keys(explain).length) item.explain = explain;
      return item;
    });
}

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
  const candidates = Array.isArray(body.candidates) ? body.candidates : [];
  if (candidates.length > MAX_CANDIDATES) return 'too many candidates';
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
    const problem = validate(body);
    if (problem) return json({ error: problem }, 400);
    if (body.mode === 'followup') return handleFollowup(body, env);

    const candidates = (body.candidates || []).slice(0, MAX_CANDIDATES).map((c) => ({
      law: String(c.law || '').slice(0, 40),
      article: String(c.article || '').slice(0, 20),
      text: String(c.text || '').slice(0, MAX_TEXT),
    }));
    const requestBody = JSON.stringify({
      contents: [{ role: 'user', parts: [{ text: buildPrompt(body.query.trim(), candidates, pickLanguages(body.languages)) }] }],
      ...(env.USE_SEARCH === 'true' ? { tools: [{ google_search: {} }] } : {}),
      generationConfig: { temperature: 0.2, maxOutputTokens: 8192, responseMimeType: 'application/json' },
    });
    // Models are tried in order; busy, over-quota or retired models fall through to the next.
    const models = String(env.GEMINI_MODEL || '')
      .split(',')
      .map(normalizeModel)
      .filter((m, i, a) => a.indexOf(m) === i);
    const attempts = [];
    for (const model of models) {
      try {
        const res = await fetch(
          `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`,
          {
            signal: AbortSignal.timeout(14000),
            method: 'POST',
            headers: {
              'content-type': 'application/json',
              'x-goog-api-key': env.GEMINI_API_KEY,
            },
            body: requestBody,
          },
        );
        if (res.ok) {
          const data = await res.json();
          const candidate = data.candidates && data.candidates[0];
          const text = ((candidate && candidate.content && candidate.content.parts) || [])
            .map((p) => p.text || '')
            .join('');
          try {
            const ranked = parseModelJson(text);
            const chunks = (candidate && candidate.groundingMetadata && candidate.groundingMetadata.groundingChunks) || [];
            const sources = chunks
              .map((c) => c.web && c.web.title)
              .filter(Boolean)
              .slice(0, 5)
              .map((title) => ({ title }));
            return json({ ranked, sources });
          } catch {
            attempts.push({ model, status: 200, message: 'unparseable output' });
            console.error('Gemini output unparseable', {
              model,
              finishReason: candidate && candidate.finishReason,
              length: text.length,
            });
            continue;
          }
        }
        // Logs only: model and Google's error text (no key, token or narrative).
        const errorText = (await res.text()).slice(0, 2000);
        attempts.push({ model, ...summarizeUpstreamError(res.status, errorText) });
        console.error('Gemini upstream request failed', { model, status: res.status, error: errorText.slice(0, 600) });
      } catch (err) {
        attempts.push({ model, status: 0, message: (err && err.name) || 'fetch failed' });
        console.error('Gemini request failed', { model, name: err && err.name });
      }
    }
    return json({ error: 'upstream error', attempts }, 502);
  },
};
