'use client';
import { createContext, useContext, useEffect, useMemo, useState } from 'react';
import type { Kitchen } from '@/lib/types';
import { ymd } from '@/lib/export';

type Scope = {
  kitchens: Kitchen[];
  kitchenId: string;
  from: string;
  to: string;
  setKitchenId: (v: string) => void;
  setFrom: (v: string) => void;
  setTo: (v: string) => void;
  kitchen: Kitchen | undefined;
};

const Ctx = createContext<Scope | null>(null);
const KEY = 'kms.scope.v1';

export function ScopeProvider({ kitchens, children }: { kitchens: Kitchen[]; children: React.ReactNode }) {
  const now = new Date();
  const [kitchenId, setKitchenId] = useState(kitchens[0]?.id ?? '');
  const [from, setFrom] = useState(ymd(new Date(now.getFullYear(), now.getMonth(), 1)));
  const [to, setTo] = useState(ymd(now));

  // استرجاع آخر اختيار
  useEffect(() => {
    try {
      const s = JSON.parse(localStorage.getItem(KEY) ?? 'null');
      if (s?.kitchenId && kitchens.some((k) => k.id === s.kitchenId)) setKitchenId(s.kitchenId);
      if (s?.from) setFrom(s.from);
      if (s?.to) setTo(s.to);
    } catch { /* ignore */ }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  useEffect(() => {
    try { localStorage.setItem(KEY, JSON.stringify({ kitchenId, from, to })); } catch { /* ignore */ }
  }, [kitchenId, from, to]);

  const value = useMemo<Scope>(() => ({
    kitchens, kitchenId, from, to, setKitchenId, setFrom, setTo,
    kitchen: kitchens.find((k) => k.id === kitchenId),
  }), [kitchens, kitchenId, from, to]);

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useScope(): Scope {
  const v = useContext(Ctx);
  if (!v) throw new Error('useScope must be used inside ScopeProvider');
  return v;
}
