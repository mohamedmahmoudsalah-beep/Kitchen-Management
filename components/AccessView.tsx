'use client';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { createClient } from '@/lib/supabase/client';
import type { Kitchen, PageDef, Profile, Role } from '@/lib/types';

const ROLES: Role[] = ['admin', 'manager', 'kitchen_user', 'viewer'];
type Invite = { email: string; role: Role; is_active: boolean; kitchen_ids: string[]; page_keys: string[] };
type Values = { role: Role; active: boolean; kitchens: string[]; pages: string[] };

function Editor({ kitchens, pages, initial, locked, submitLabel, onSubmit, email, onEmail }: {
  kitchens: Kitchen[]; pages: PageDef[]; initial: Values; locked?: boolean; submitLabel: string;
  onSubmit: (v: Values) => Promise<void>; email?: string; onEmail?: (v: string) => void;
}) {
  const [v, setV] = useState<Values>(initial);
  const [busy, setBusy] = useState(false);
  const assignable = pages.filter((p) => p.key !== 'access_control');
  const toggle = (arr: string[], x: string) => (arr.includes(x) ? arr.filter((y) => y !== x) : [...arr, x]);
  const isAdminRole = v.role === 'admin';

  return (
    <div style={{ display: 'grid', gap: 12 }}>
      {onEmail && (
        <label className="field" style={{ maxWidth: 360 }}><span>Email</span>
          <input type="email" value={email ?? ''} onChange={(e) => onEmail(e.target.value)} placeholder="name@breadfast.com" />
        </label>
      )}
      <div className="form-row">
        <label className="field"><span>Role</span>
          <select value={v.role} disabled={locked} onChange={(e) => setV({ ...v, role: e.target.value as Role })}>
            {ROLES.map((r) => <option key={r} value={r}>{r}</option>)}
          </select>
        </label>
        <label className="checks" style={{ paddingBottom: 6 }}>
          <span><input type="checkbox" checked={v.active} disabled={locked} onChange={(e) => setV({ ...v, active: e.target.checked })} /> Active</span>
        </label>
      </div>
      {isAdminRole && <div className="muted">Admin بيشوف كل المطابخ والصفحات تلقائيًا.</div>}
      <div className={isAdminRole ? 'muted' : ''}>
        <div className="field"><span>Kitchens</span></div>
        <div className="checks">
          {kitchens.map((k) => (
            <label key={k.id}><input type="checkbox" disabled={locked || isAdminRole} checked={v.kitchens.includes(k.id)}
              onChange={() => setV({ ...v, kitchens: toggle(v.kitchens, k.id) })} /> {k.name}</label>
          ))}
          <button className="btn secondary small" type="button" disabled={locked || isAdminRole}
            onClick={() => setV({ ...v, kitchens: kitchens.map((k) => k.id) })}>All</button>
        </div>
      </div>
      <div className={isAdminRole ? 'muted' : ''}>
        <div className="field"><span>Pages</span></div>
        <div className="checks">
          {assignable.map((p) => (
            <label key={p.key}><input type="checkbox" disabled={locked || isAdminRole} checked={v.pages.includes(p.key)}
              onChange={() => setV({ ...v, pages: toggle(v.pages, p.key) })} /> {p.title}</label>
          ))}
          <button className="btn secondary small" type="button" disabled={locked || isAdminRole}
            onClick={() => setV({ ...v, pages: assignable.map((p) => p.key) })}>All</button>
        </div>
      </div>
      <div>
        <button className="btn" disabled={busy || locked} onClick={async () => { setBusy(true); try { await onSubmit(v); } finally { setBusy(false); } }}>
          {busy ? 'Saving…' : submitLabel}
        </button>
      </div>
    </div>
  );
}

export default function AccessView() {
  const supabase = useMemo(() => createClient(), []);
  const [profiles, setProfiles] = useState<Profile[]>([]);
  const [uk, setUk] = useState<{ user_id: string; kitchen_id: string }[]>([]);
  const [up, setUp] = useState<{ user_id: string; page_key: string }[]>([]);
  const [invites, setInvites] = useState<Invite[]>([]);
  const [kitchens, setKitchens] = useState<Kitchen[]>([]);
  const [pages, setPages] = useState<PageDef[]>([]);
  const [open, setOpen] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ kind: 'ok' | 'err'; text: string } | null>(null);
  const [inviteEmail, setInviteEmail] = useState('');
  const [inviteKey, setInviteKey] = useState(0);

  const load = useCallback(async () => {
    const [p, a, b, i, k, g] = await Promise.all([
      supabase.from('profiles').select('user_id,email,full_name,role,is_active,is_root').order('email'),
      supabase.from('user_kitchens').select('user_id,kitchen_id'),
      supabase.from('user_pages').select('user_id,page_key'),
      supabase.from('access_invites').select('email,role,is_active,kitchen_ids,page_keys').order('email'),
      supabase.from('kitchens').select('id,code,name').order('name'),
      supabase.from('pages').select('key,title,sort').order('sort'),
    ]);
    const firstErr = [p, a, b, i, k, g].find((r) => r.error)?.error;
    if (firstErr) { setMsg({ kind: 'err', text: firstErr.message }); return; }
    setProfiles((p.data ?? []) as Profile[]); setUk(a.data ?? []); setUp(b.data ?? []);
    setInvites((i.data ?? []) as Invite[]); setKitchens((k.data ?? []) as Kitchen[]); setPages((g.data ?? []) as PageDef[]);
  }, [supabase]);

  useEffect(() => { load(); }, [load]);

  const sorted = [...profiles].sort((a, b) => Number(a.is_active) - Number(b.is_active) || a.email.localeCompare(b.email));
  const kitchenName = (id: string) => kitchens.find((k) => k.id === id)?.name ?? id;

  async function save(p: Profile, v: Values) {
    const { error } = await supabase.rpc('set_user_access', {
      p_user: p.user_id, p_role: v.role, p_active: v.active, p_kitchens: v.kitchens, p_pages: v.pages,
    });
    if (error) setMsg({ kind: 'err', text: error.message });
    else { setMsg({ kind: 'ok', text: `اتحفظت صلاحيات ${p.email}` }); setOpen(null); await load(); }
  }

  async function invite(v: Values) {
    const { error } = await supabase.rpc('invite_user', {
      p_email: inviteEmail, p_role: v.role, p_active: v.active, p_kitchens: v.kitchens, p_pages: v.pages,
    });
    if (error) setMsg({ kind: 'err', text: error.message });
    else { setMsg({ kind: 'ok', text: `الدعوة اتسجلت لـ ${inviteEmail.toLowerCase()} — الصلاحيات هتتطبق أول ما يدخل بجوجل.` }); setInviteEmail(''); setInviteKey((k) => k + 1); await load(); }
  }

  async function removeInvite(email: string) {
    const { error } = await supabase.rpc('delete_invite', { p_email: email });
    if (error) setMsg({ kind: 'err', text: error.message }); else await load();
  }

  return (
    <>
      {msg && <div className={`alert ${msg.kind}`} dir="auto">{msg.text}</div>}

      <div className="panel flush">
        <div className="toolbar"><b>Users</b><span className="muted">{profiles.length} users</span></div>
        <div className="table-wrap">
          <table className="grid">
            <thead><tr><th>Email</th><th>Role</th><th>Status</th><th>Kitchens</th><th>Pages</th><th /></tr></thead>
            <tbody>
              {sorted.map((p) => {
                const ks = uk.filter((x) => x.user_id === p.user_id).map((x) => x.kitchen_id);
                const ps = up.filter((x) => x.user_id === p.user_id).map((x) => x.page_key);
                const isOpen = open === p.user_id;
                return (
                  <FragmentRow key={p.user_id}
                    cells={
                      <>
                        <td>{p.email} {p.is_root && <span className="badge magenta">Root</span>}{p.full_name && <div className="muted">{p.full_name}</div>}</td>
                        <td>{p.role}</td>
                        <td>{p.is_active ? <span className="badge ok">Active</span> : <span className="badge warn">Pending activation</span>}</td>
                        <td>{p.role === 'admin' ? 'All' : ks.map(kitchenName).join(', ') || <span className="muted">—</span>}</td>
                        <td>{p.role === 'admin' ? 'All' : ps.length}</td>
                        <td><button className="btn secondary small" onClick={() => setOpen(isOpen ? null : p.user_id)}>{isOpen ? 'Close' : 'Edit'}</button></td>
                      </>
                    }
                    detail={isOpen ? (
                      <Editor kitchens={kitchens} pages={pages} locked={p.is_root} submitLabel="Save access"
                        initial={{ role: p.role, active: p.is_active, kitchens: ks, pages: ps }} onSubmit={(v) => save(p, v)} />
                    ) : null}
                  />
                );
              })}
              {!profiles.length && <tr><td colSpan={6} className="empty">No users</td></tr>}
            </tbody>
          </table>
        </div>
      </div>

      {invites.length > 0 && (
        <div className="panel flush">
          <div className="toolbar"><b>Invited (not signed in yet)</b></div>
          <table className="grid">
            <thead><tr><th>Email</th><th>Role</th><th>Kitchens</th><th>Pages</th><th /></tr></thead>
            <tbody>
              {invites.map((i) => (
                <tr key={i.email}>
                  <td>{i.email}</td><td>{i.role}</td>
                  <td>{i.kitchen_ids.map(kitchenName).join(', ') || '—'}</td><td>{i.page_keys.length}</td>
                  <td><button className="btn danger small" onClick={() => removeInvite(i.email)}>Remove</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <div className="panel">
        <h2>Add user (pre-register by email)</h2>
        <p className="muted" style={{ marginTop: 0 }} dir="auto">
          سجّل الإيميل وصلاحياته قبل أول دخول. أي حد بإيميل @breadfast.com يدخل من غير دعوة بيتعمله Profile غير Active وبيظهر فوق في Pending عشان تفعّله.
        </p>
        {kitchens.length > 0 && (
          <Editor key={inviteKey} kitchens={kitchens} pages={pages} submitLabel="Add user" email={inviteEmail} onEmail={setInviteEmail}
            initial={{ role: 'kitchen_user', active: true, kitchens: [], pages: [] }} onSubmit={invite} />
        )}
      </div>
    </>
  );
}

function FragmentRow({ cells, detail }: { cells: React.ReactNode; detail: React.ReactNode }) {
  return (
    <>
      <tr>{cells}</tr>
      {detail && <tr><td colSpan={6} style={{ background: '#fafbfd' }}>{detail}</td></tr>}
    </>
  );
}
