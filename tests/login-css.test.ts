import fs from 'fs';
import path from 'path';
import { describe, expect, it } from 'vitest';

// صفحة الدخول ليها CSS خاص: مينفعش يتسرّب على باقي النظام (html/body/*/:root/h1 عامة…)
const css = fs.readFileSync(path.join(process.cwd(), 'app/login/login.css'), 'utf8');
const stripped = css.replace(/\/\*[\s\S]*?\*\//g, '');

function selectors(src: string): string[] {
  const out: string[] = [];
  let depth = 0; let buf = '';
  const frames: { at: boolean }[] = [];
  for (const ch of src) {
    if (ch === '{') {
      const sel = buf.trim(); buf = '';
      const at = sel.startsWith('@');
      const inKeyframes = frames.some((f) => f.at);
      if (!at && !inKeyframes) out.push(...sel.split(',').map((s) => s.trim()).filter(Boolean));
      if (at && /@(media|supports)/.test(sel)) frames.push({ at: false });
      else frames.push({ at });
      depth++;
    } else if (ch === '}') { depth--; frames.pop(); buf = ''; }
    else if (ch === ';' && depth >= 0) { buf += ch; }
    else buf += ch;
    if (ch === ';') buf = buf.slice(buf.lastIndexOf(';') + 1);
  }
  return out;
}

describe('login.css is isolated from the rest of the app', () => {
  const sels = selectors(stripped);
  it('has rules', () => expect(sels.length).toBeGreaterThan(80));
  it('every selector lives under .kp-portal-shell or uses kp- classes only', () => {
    const bad = sels.filter((s) => !/^\.kp-[a-z0-9-]+/.test(s));
    expect(bad).toEqual([]);
  });
  it('no global element / root rules', () => {
    for (const s of sels) expect(s).not.toMatch(/^(html|body|:root|\*|h1|h2|button|input|a|p)\b/);
  });
  it('keyframes are prefixed kp- (keyframe names are global, so no clash with the app)', () => {
    const names = [...stripped.matchAll(/@keyframes\s+([\w-]+)/g)].map((m) => m[1]);
    expect(names.length).toBeGreaterThan(0);
    for (const n of names) expect(n.startsWith('kp-')).toBe(true);
    expect(new Set(names).size).toBe(names.length);
    // وكل animation مستخدم له keyframes
    for (const m of stripped.matchAll(/animation:\s*([\w-]+)/g)) expect(names).toContain(m[1]);
  });
  it('uses the public image paths that exist', () => {
    for (const m of stripped.matchAll(/url\("([^"]+)"\)/g)) expect(fs.existsSync(path.join(process.cwd(), 'public', m[1]))).toBe(true);
  });
});
