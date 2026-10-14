'use client';
import { useMemo, useState } from 'react';
import { Trash2 } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { useScope } from '@/components/ScopeProvider';
import { buildArchive, purgePhrase } from '@/lib/archive';
import { saveBlob } from '@/lib/export';
import { curMonth, monthRange } from '@/lib/months';

type Preview = { ok: boolean; blockers: string[]; counts: { documents: number; lines: number; ledger: number; audit: number; carry_rows: number; kept_transfers?: number } };

// أرشفة ومسح شهور قديمة (Admin): فحص ← تنزيل الصفحات كلها ← تأكيد بالكتابة ← مسح.
// الرصيد بيتحفظ كمستند ترحيل (ARC-…) لكل مطبخ، فأرصدة وتقارير الشهور الجديدة مبتتأثرش.
export default function ArchivePurgePanel() {
  const supabase = useMemo(() => createClient(), []);
  const { kitchens } = useScope();
  const [sel, setSel] = useState('ALL');           // ALL أو id مطبخ
  const [mFrom, setMFrom] = useState('');
  const [mTo, setMTo] = useState('');
  const [prev, setPrev] = useState<Preview | null>(null);
  const [downloaded, setDownloaded] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [confirm, setConfirm] = useState('');
  const [msg, setMsg] = useState<{ kind: 'ok' | 'err'; text: string } | null>(null);
  const range = monthRange(mFrom, mTo);
  const one = sel === 'ALL' ? null : kitchens.find((k) => k.id === sel) ?? null;
  const scoped = one ? [one] : kitchens;
  const phrase = range ? purgePhrase(mFrom, mTo, one?.code) : '';

  const reset = () => { setPrev(null); setDownloaded(false); setConfirm(''); };

  async function check() {
    if (!range) return;
    setBusy('check'); setMsg(null); reset();
    const { data, error } = await supabase.rpc('purge_preview', { p_from: range.from, p_to: range.to, p_kitchen: one?.id ?? null });
    if (error) setMsg({ kind: 'err', text: error.message }); else setPrev(data as Preview);
    setBusy(null);
  }

  async function download() {
    if (!range) return;
    setBusy('download'); setMsg(null);
    try {
      const a = await buildArchive(supabase, { kitchens: scoped, skipTransfers: !!one, from: range.from, to: range.to, onProgress: (m) => setBusy(`download: ${m}`) });
      saveBlob(a.blob, a.name);
      setDownloaded(true);
    } catch (e) { setMsg({ kind: 'err', text: `التنزيل فشل — المسح مش متاح: ${e instanceof Error ? e.message : String(e)}` }); }
    setBusy(null);
  }

  async function purge() {
    if (!range) return;
    setBusy('purge'); setMsg(null);
    const { data, error } = await supabase.rpc('purge_range', { p_from: range.from, p_to: range.to, p_confirm: confirm, p_kitchen: one?.id ?? null });
    if (error) setMsg({ kind: 'err', text: error.message });
    else { setMsg({ kind: 'ok', text: `تم المسح: ${JSON.stringify(data)}` }); reset(); }
    setBusy(null);
  }

  return (
    <div className="panel" style={{ marginTop: 16 }} dir="auto">
      <h2 style={{ display: 'flex', gap: 8, alignItems: 'center' }}><Trash2 size={18} /> أرشفة ومسح شهور قديمة (Admin)</h2>
      <p className="muted">
        بتمسح مستندات وحركات وسجل Audit شهور قديمة عشان الداتا بيز متكبرش — لمطبخ محدد أو لكل المطابخ (اختار من القايمة). مطبخ واحد: المستندات اللي تخصه ماعدا <b>التحويلات بين المطابخ</b> (بتفضل، وبتتمسح من اختيار كل المطابخ). شروط: شهور كاملة قبل الشهر الحالي، ومفيش تحويل مفتوح. مش لازم الفترة تكون مقفولة.
        الأول بتنزّل الصفحات (Excel)، وبعدها تكتب جملة التأكيد. الرصيد بيتحفظ كمستند ترحيل واحد لكل مطبخ فالشهور اللي بعدها مبتتأثرش، والفترة المحذوفة بتتقفل تلقائيًا للمطبخ المختار (أو كل المطابخ). الـ Product Card للشهور المحذوفة هيبقى سطر ترحيل واحد.
      </p>
      <div className="form-row">
        <label className="field"><span>Kitchen</span>
          <select value={sel} onChange={(e) => { setSel(e.target.value); reset(); }}>
            <option value="ALL">All kitchens</option>
            {kitchens.map((k) => <option key={k.id} value={k.id}>{k.name}</option>)}
          </select></label>
        <label className="field"><span>From month</span><input type="month" value={mFrom} max={mTo || curMonth()} onChange={(e) => { setMFrom(e.target.value); reset(); }} /></label>
        <label className="field"><span>To month</span><input type="month" value={mTo} min={mFrom} max={curMonth()} onChange={(e) => { setMTo(e.target.value); reset(); }} /></label>
        <button className="btn secondary" disabled={!range || !!busy} onClick={check}>{busy === 'check' ? 'Checking…' : '1) Check'}</button>
      </div>

      {prev && (
        <div style={{ marginTop: 12 }}>
          <div className="muted">المستندات: <b>{prev.counts.documents}</b> · السطور: <b>{prev.counts.lines}</b> · حركات Ledger: <b>{prev.counts.ledger}</b> · Audit: <b>{prev.counts.audit}</b> · صفوف الترحيل: <b>{prev.counts.carry_rows}</b>{one && !!prev.counts.kept_transfers && <> · تحويلات هتفضل: <b>{prev.counts.kept_transfers}</b></>}</div>
          {!prev.ok && (
            <div className="alert err" style={{ marginTop: 8 }}>
              <b>المسح مش متاح:</b>
              <ul style={{ margin: '6px 18px' }}>{prev.blockers.map((b, i) => <li key={i}>{b}</li>)}</ul>
            </div>
          )}
          {prev.ok && (
            <div style={{ marginTop: 10 }}>
              <div className="form-row">
                <button className="btn" disabled={!!busy} onClick={download}>{busy?.startsWith('download') ? `Downloading… ${busy.slice(10)}` : '2) Download all pages (ZIP)'}</button>
                {downloaded && <span className="badge ok">اتنزّل</span>}
              </div>
              <div className="form-row" style={{ marginTop: 10 }}>
                <label className="field" style={{ minWidth: 340 }}><span>اكتب للتأكيد: <b dir="ltr">{phrase}</b></span>
                  <input type="text" dir="ltr" value={confirm} disabled={!downloaded} onChange={(e) => setConfirm(e.target.value)} /></label>
                <button className="btn" style={{ background: 'var(--err)' }} disabled={!downloaded || confirm !== phrase || !!busy} onClick={purge}>
                  <Trash2 size={14} /> {busy === 'purge' ? 'Deleting…' : '3) Delete permanently'}
                </button>
              </div>
            </div>
          )}
        </div>
      )}
      {msg && <div className={`alert ${msg.kind}`} style={{ marginTop: 10 }}>{msg.text}</div>}
    </div>
  );
}
