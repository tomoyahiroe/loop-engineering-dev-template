import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { parse } from 'smol-toml';

const isPlainObject = (v) =>
  typeof v === 'object' && v !== null && !Array.isArray(v);

export function deepMerge(base, over) {
  const out = { ...base };
  for (const [k, v] of Object.entries(over)) {
    out[k] = isPlainObject(v) && isPlainObject(base[k]) ? deepMerge(base[k], v) : v;
  }
  return out;
}

export function loadConfig(loopDir) {
  const defaultsPath = join(loopDir, 'defaults.toml');
  if (!existsSync(defaultsPath)) {
    throw new Error(`defaults.toml が見つからない: ${defaultsPath}`);
  }
  const defaults = parse(readFileSync(defaultsPath, 'utf8'));
  const overridePath = join(loopDir, 'config.toml');
  const overrides = existsSync(overridePath)
    ? parse(readFileSync(overridePath, 'utf8'))
    : {};
  return deepMerge(defaults, overrides);
}

export function getKey(cfg, dotted) {
  return dotted
    .split('.')
    .reduce((o, k) => (o === null || o === undefined ? undefined : o[k]), cfg);
}

export function formatValue(v) {
  if (v === undefined || v === null) return null;
  if (Array.isArray(v)) return v.join('\n');
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  return String(v);
}
