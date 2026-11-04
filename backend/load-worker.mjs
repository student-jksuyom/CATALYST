// worker.js is an ES module without a package.json "type"; import it through a data URL.
import { readFileSync } from 'node:fs';

export async function loadWorker() {
  const source = readFileSync(new URL('./worker.js', import.meta.url), 'utf8');
  return import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
}

export function readModels() {
  const toml = readFileSync(new URL('./wrangler.toml', import.meta.url), 'utf8');
  const match = toml.match(/^GEMINI_MODEL\s*=\s*"([^"]+)"/m);
  return match ? match[1].split(',').map((m) => m.trim()) : [];
}
