# CATALYST XAI follow-up proxy

Handles XAI follow-up only; article retrieval and its offline evidence do not
call this proxy. The source must be deployed before an existing Worker changes.
Keeps the Gemini API key off the phone. Runs on the Cloudflare Workers free plan
(no billing account needed).

1. Get a free Gemini key at https://aistudio.google.com. Do not enable billing, so quota overruns are rejected instead of charged.
2. Install Node.js, then in this folder:
   - `npx wrangler login`
   - `npx wrangler secret put GEMINI_API_KEY`
   - `npx wrangler secret put APP_TOKEN` (any long random string; the app sends it)
   - `npx wrangler deploy` -> prints the URL, e.g. `https://catalyst-proxy.<you>.workers.dev`
3. Set `GEMINI_MODEL` in wrangler.toml to a model your key can use with Google Search grounding on the free tier; check current limits at https://ai.google.dev/gemini-api/docs/pricing.
4. Build the app with the URL (keep this file out of version control):

   `env.json`: `{"CATALYST_API_URL":"https://catalyst-proxy.<you>.workers.dev","CATALYST_API_TOKEN":"<APP_TOKEN>"}`

   `flutter build apk --debug --dart-define-from-file=env.json`

Without `CATALYST_API_URL` XAI follow-up uses its on-device fallback. Article
retrieval is always on-device, regardless of this setting. The token is inside
the APK, so it only deters casual abuse; the Gemini key stays on the Worker.

Free-tier requests may be used by Google to improve its models, and narratives leave the device; tell users.
