import { describe, expect, it } from 'vitest';
import { explainAuthError } from '@/lib/auth-errors';

describe('explainAuthError', () => {
  it('returns null when there is no error', () => {
    expect(explainAuthError(null, null)).toBeNull();
    expect(explainAuthError('', '')).toBeNull();
  });
  it('explains a failed account creation (the usual cause of bouncing back to login)', () => {
    expect(explainAuthError('server_error', 'Database error saving new user')?.title).toContain('نسجّل');
    expect(explainAuthError('server_error', 'Database error saving new user')?.hint).toContain('008');
  });
  it('explains PKCE / redirect / consent / key problems', () => {
    expect(explainAuthError('exchange_failed', 'both auth code and code verifier should be non-empty')?.title).toContain('الجلسة');
    expect(explainAuthError('x', 'redirect_uri_mismatch')?.title).toContain('رابط الرجوع');
    expect(explainAuthError('access_denied', null)?.title).toContain('جوجل');
    expect(explainAuthError('x', 'Invalid API key')?.title).toContain('مفتاح');
  });
  it('falls back to a generic message and always keeps the raw error visible to the caller', () => {
    expect(explainAuthError('weird', 'something else')?.title).toContain('مشكلة');
  });
});
