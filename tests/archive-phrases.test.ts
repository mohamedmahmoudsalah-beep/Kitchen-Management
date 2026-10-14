import { describe, expect, it } from 'vitest';
import { clearPagePhrase, purgePhrase } from '@/lib/archive';

describe('confirmation phrases match the DB', () => {
  it('purge phrase: all kitchens vs one kitchen', () => {
    expect(purgePhrase('2026-01', '2026-03')).toBe('PURGE 2026-01 → 2026-03');
    expect(purgePhrase('2026-01', '2026-03', 'MAADI')).toBe('PURGE 2026-01 → 2026-03 @ MAADI');
    expect(purgePhrase('2026-01', '2026-03', null)).toBe('PURGE 2026-01 → 2026-03');
  });
  it('clear page phrase', () => {
    expect(clearPagePhrase('import_errors')).toBe('CLEAR import_errors @ ALL');
    expect(clearPagePhrase('import_errors', 'NC7')).toBe('CLEAR import_errors @ NC7');
  });
});
