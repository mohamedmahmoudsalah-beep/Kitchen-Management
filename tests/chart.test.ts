import { describe, expect, it } from 'vitest';
import { compact, linePath, nearestIndex, niceTicks } from '@/lib/chart';

describe('chart helpers', () => {
  it('compact numbers', () => {
    expect(compact(0)).toBe('0'); expect(compact(950)).toBe('950'); expect(compact(1500)).toBe('1.5K');
    expect(compact(3189061)).toBe('3.2M'); expect(compact(2_000_000_000)).toBe('2B');
  });
  it('niceTicks start at 0 and cover the max', () => {
    for (const m of [1, 7, 99, 1234, 3189061, 0.4]) {
      const t = niceTicks(m);
      expect(t[0]).toBe(0); expect(t[t.length - 1]).toBeGreaterThanOrEqual(m); expect(t.length).toBeLessThanOrEqual(8);
    }
    expect(niceTicks(0)).toEqual([0, 1]);
  });
  it('linePath breaks on nulls', () => {
    expect(linePath([0, 10, 20], [5, null, 7])).toBe('M0.0,5.0M20.0,7.0');
    expect(linePath([0, 10], [1, 2])).toBe('M0.0,1.0L10.0,2.0');
  });
  it('nearestIndex clamps', () => {
    expect(nearestIndex(-50, 10, 100, 5)).toBe(0); expect(nearestIndex(500, 10, 100, 5)).toBe(4);
    expect(nearestIndex(60, 10, 100, 5)).toBe(2); expect(nearestIndex(60, 10, 100, 1)).toBe(0);
  });
});
