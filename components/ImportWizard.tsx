'use client';
import { useEffect, useMemo, useRef, useState } from 'react';
import { useSearchParams } from 'next/navigation';
import Link from 'next/link';
import { Download, FileUp, ShieldAlert } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import ReasonsPanel from '@/components/ReasonsPanel';
import { useScope } from '@/components/ScopeProvider';
import { MODULES, MODULE_ORDER, mapRows, FIELD_LABEL, type ImportModule, type MappedFile } from '@/lib/import/columns';
import { readTable } from '@/lib/import/parse-file';
import { downloadCsv, ymd } from '@/lib/export';

type Phase = 'idle' | 'parsed' | 'validating' | 'invalid' | 'valid' | 'committing' | 'done';
type ErrRow = { row_no: number; column_name: string | null; reason: string; raw: Record<string, unknown> | null };

const CHUNK = 1000;

type ImportMode = 'upsert' | 'insert' | 'update';

export default function ImportWizard({ allowed, isAdmin, fixedModule, initialMode = 'upsert', onDone }: {
  allowed: ImportModule[]; isAdmin: boolean; fixedModule?: ImportModule; initialMode?: ImportMode; onDone?: () => void;
}) {
  const params = useSearchParams();
  const { kitchen } = useScope();
  const supabase = useMemo(() => createClient(), []);
  const fileRef = useRef<HTMLInputElement>(null);

  const first = params.get('module') as ImportModule | null;
  const [module, setModule] = useState<ImportModule>(fixedModule ?? (first && allowed.includes(first) ? first : allowed[0]));
  const [importMode, setImportMode] = useState<ImportMode>(initialMode);
  const [qtyMode, setQtyMode] = useState<'PIECE' | 'BASE'>('BASE');
  const [override, setOverride] = useState('');
  const [file, setFile] = useState<File | null>(null);
  const [parsed, setParsed] = useState<MappedFile | null>(null);
  const [phase, setPhase] = useState<Phase>('idle');
  const [batch, setBatch] = useState<string | null>(null);
  const [errors, setErrors] = useState<ErrRow[]>([]);
  const [errCount, setErrCount] = useState(0);
  const [message, setMessage] = useState<{ kind: 'err' | 'ok'; text: string } | null>(null);

  const [batchKitchen, setBatchKitchen] = useState('');
  const spec = MODULES[module];
  const busy = phase === 'validating' || phase === 'committing';

  function reset(keepFile = false) {
    setPhase(keepFile && parsed ? 'parsed' : 'idle'); setBatch(null); setErrors([]); setErrCount(0); setMessage(null);
    if (!keepFile) { setFile(null); setParsed(null); if (fileRef.current) fileRef.current.value = ''; }
  }

  // لو المطبخ اتغيّر بعد الفحص، الـ Batch القديم ملوش لازمة
  useEffect(() => {
    if (phase === 'valid' || phase === 'invalid') reset(true);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [kitchen?.id]);

  async function onFile(f: File | null) {
    reset();
    if (!f) return;
    setFile(f);
    try {
      const table = await readTable(f);
      const m = mapRows(table, spec);
      setParsed(m);
      setPhase('parsed');
    } catch (e) {
      setMessage({ kind: 'err', text: e instanceof Error ? e.message : 'مقدرتش أقرا الملف' });
    }
  }

  async function onModuleChange(m: ImportModule) {
    setModule(m);
    reset(false);
  }

  async function validate() {
    if (!file || !parsed) return;
    setPhase('validating'); setMessage(null); setErrors([]);
    try {
      const { data: id, error: e1 } = await supabase.rpc('import_start', {
        p_module: module, p_kitchen: spec.needsKitchen ? kitchen?.id ?? null : null,
        p_file: file.name, p_total: parsed.rows.length, p_qty_mode: qtyMode, p_mode: importMode,
      });
      if (e1) throw e1;
      setBatch(id as string); setBatchKitchen(kitchen?.name ?? '');
      for (let i = 0; i < parsed.rows.length; i += CHUNK) {
        const { error } = await supabase.rpc('import_stage_rows', { p_batch: id, p_rows: parsed.rows.slice(i, i + CHUNK) });
        if (error) throw error;
      }
      const { data: res, error: e2 } = await supabase.rpc('import_validate', {
        p_batch: id, p_override_reason: override.trim() || null,
      });
      if (e2) throw e2;
      if (res.ok) { setPhase('valid'); return; }
      setErrCount(res.errors);
      const { data: errs } = await supabase.from('import_errors')
        .select('row_no,column_name,reason,raw').eq('batch_id', id).order('row_no').limit(1000);
      setErrors((errs ?? []) as ErrRow[]);
      setPhase('invalid');
    } catch (e) {
      setMessage({ kind: 'err', text: (e as { message?: string }).message ?? 'حصلت مشكلة' });
      setPhase('parsed');
    }
  }

  async function commit() {
    if (!batch) return;
    setPhase('committing'); setMessage(null);
    try {
      const { data: res, error } = await supabase.rpc('import_commit', { p_batch: batch });
      if (error) throw error;
      if (!res.ok) {
        setErrCount(res.errors);
        const { data: errs } = await supabase.from('import_errors')
          .select('row_no,column_name,reason,raw').eq('batch_id', batch).order('row_no').limit(1000);
        setErrors((errs ?? []) as ErrRow[]);
        setPhase('invalid');
        return;
      }
      const text = module === 'products'
        ? `اتحفظ: ${res.inserted} منتج جديد و ${res.updated} منتج اتحدّث.`
        : `اتحفظ ${res.lines} سطر في ${res.documents} مستند (Posted) للمطبخ ${batchKitchen}.`;
      setMessage({ kind: 'ok', text }); setPhase('done'); onDone?.();
    } catch (e) {
      setMessage({ kind: 'err', text: (e as { message?: string }).message ?? 'حصلت مشكلة' });
      setPhase('valid');
    }
  }

  const missingText = parsed?.missing.map((k) => FIELD_LABEL[k] ?? k).join(', ');
  const canValidate = !!parsed && parsed.missing.length === 0 && parsed.rows.length > 0 && !busy
    && (!spec.needsKitchen || !!kitchen) && (phase === 'parsed' || phase === 'invalid' || phase === 'valid');

  return (
    <>
      <div className="panel">
        <h2>1. What and where</h2>
        <div className="form-row">
          {!fixedModule && (
            <label className="field"><span>Module</span>
              <select value={module} onChange={(e) => onModuleChange(e.target.value as ImportModule)} disabled={busy}>
                {MODULE_ORDER.filter((m) => allowed.includes(m)).map((m) => <option key={m} value={m}>{MODULES[m].label}</option>)}
              </select>
            </label>
          )}
          {module === 'products' && (
            <label className="field"><span>What to do with the file</span>
              <select value={importMode} onChange={(e) => { setImportMode(e.target.value as ImportMode); if (phase !== 'idle') reset(true); }} disabled={busy}>
                <option value="upsert">Add new + update existing</option>
                <option value="insert">Add new only (existing Syt = error)</option>
                <option value="update">Update existing only (unknown Syt = error)</option>
              </select>
            </label>
          )}
          {spec.needsKitchen && (
            <div className="field"><span>Location (branch from the top bar)</span>
              <div className="badge magenta" style={{ padding: '6px 12px', fontSize: '.95rem' }}>{kitchen?.name ?? '—'}</div>
            </div>
          )}
          {spec.usesQty && (
            <label className="field"><span>Qty column means</span>
              <select value={qtyMode} onChange={(e) => { setQtyMode(e.target.value as 'PIECE' | 'BASE'); if (phase !== 'idle') reset(true); }} disabled={busy}>
                <option value="BASE">Base unit (كيلو / الوحدة الأساسية)</option>
                <option value="PIECE">Syt pieces (عدد الكود) × Base Qty per Syt</option>
              </select>
            </label>
          )}
          <button className="btn secondary" onClick={() => downloadCsv(`${module}-template.csv`, spec.template, [])}>
            <Download size={14} /> Template
          </button>
        </div>
        <p className="muted" style={{ margin: '10px 0 0' }} dir="auto">
          {spec.needsKitchen
            ? 'كل رفع بيتم لمطبخ واحد (اللي مختاره فوق). الأعمدة بتتقرا بالاسم والترتيب مش مهم، والأعمدة الزيادة بتتجاهل. الكمية بالكيلو (الوحدة الأساسية) افتراضيًا، وممكن تستخدم Qty Pieces أو Qty Base في الصف نفسه بدل Qty، والنظام بيحسب التاني.'
            : 'Data Product عام لكل المطابخ. Syt Code هو المفتاح. أعمدة الملف: Syt Code, Generic Code, Product Name, UoM, Product/Financial Category, Cost, Cost Pr UOM + عمود Base Qty per Syt (كود السيستم = كام كيلو). القيم الفاضية بتحافظ على القيمة الحالية، وCost / Cost Pr UOM أحدهما بيتحسب من التاني.'}
        </p>
      </div>

      {(module === 'waste' || module === 'adjustments') && (
        <ReasonsPanel compact canAdd isAdmin={isAdmin} />
      )}

      <div className="panel">
        <h2>2. File (.xlsx or .csv)</h2>
        <div className="form-row">
          <input ref={fileRef} type="file" accept=".xlsx,.csv,.txt" disabled={busy}
            onChange={(e) => onFile(e.target.files?.[0] ?? null)} />
          {isAdmin && spec.needsKitchen && (
            <label className="field" style={{ minWidth: 260 }}><span>Override reason (Admin — only for closed periods)</span>
              <input type="text" value={override} onChange={(e) => setOverride(e.target.value)} dir="auto" placeholder="سبب التسجيل في فترة مقفولة" />
            </label>
          )}
        </div>

        {parsed && (
          <div style={{ marginTop: 12 }}>
            <div><b>{parsed.rows.length}</b> data rows · mapped:{' '}
              {parsed.mapped.map((m) => <span key={m.field} className="badge ok" style={{ marginRight: 4 }}>{m.header} → {m.field}</span>)}
            </div>
            {parsed.ignored.length > 0 && (
              <div className="muted" style={{ marginTop: 4 }}>Ignored columns: {parsed.ignored.join(', ')}</div>
            )}
            {parsed.missing.length > 0 && (
              <div className="alert err" style={{ marginTop: 8 }} dir="auto">أعمدة مطلوبة ناقصة في الملف: <b>{missingText}</b></div>
            )}
            {parsed.rows.length === 0 && parsed.missing.length === 0 && <div className="alert err" style={{ marginTop: 8 }}>الملف مفيهوش صفوف داتا</div>}
          </div>
        )}
      </div>

      <div className="panel">
        <h2>3. Validate and save</h2>
        <p className="muted" style={{ marginTop: 0 }} dir="auto">
          الملف كله بيتفحص الأول. لو في غلطة واحدة (في أي صف) ولا صف بيتحفظ. لو سليم بيتحفظ كله في Transaction واحدة.
        </p>
        <div className="form-row">
          <button className="btn" disabled={!canValidate} onClick={validate}>
            <FileUp size={14} /> {phase === 'validating' ? 'Validating…' : 'Validate file'}
          </button>
          {phase === 'valid' && (
            <button className="btn" disabled={busy} onClick={commit}>
              Save {parsed?.rows.length} rows
            </button>
          )}
          {phase === 'committing' && <span className="muted">Saving…</span>}
          {phase === 'done' && <button className="btn secondary" onClick={() => reset()}>Import another file</button>}
        </div>

        {phase === 'valid' && <div className="alert ok" style={{ marginTop: 12 }} dir="auto">الملف سليم ({parsed?.rows.length} صف). دوس Save عشان يتحفظ.</div>}
        {message && <div className={`alert ${message.kind}`} style={{ marginTop: 12 }} dir="auto">{message.text}</div>}

        {phase === 'invalid' && (
          <div style={{ marginTop: 12 }}>
            <div className="alert err" dir="auto" style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
              <ShieldAlert size={16} />
              <span>فيه <b>{errCount}</b> خطأ. ولا صف اتحفظ. صلّح الملف وارفعه تاني. الأخطاء متسجلة في <Link href="/import-errors">Import Errors</Link>.</span>
              <button className="btn secondary small" style={{ marginLeft: 'auto' }}
                onClick={() => downloadCsv(`import-errors-${ymd(new Date())}.csv`, ['Row', 'Column', 'Reason', 'Raw'],
                  errors.map((e) => [e.row_no, e.column_name, e.reason, JSON.stringify(e.raw ?? {})]))}>
                <Download size={14} /> CSV
              </button>
            </div>
            <div className="panel flush" style={{ marginTop: 10 }}>
              <div className="table-wrap" style={{ maxHeight: 420 }}>
                <table className="grid">
                  <thead><tr><th className="num">Row</th><th>Column</th><th>Reason</th></tr></thead>
                  <tbody>
                    {errors.map((e, i) => (
                      <tr key={i}>
                        <td className="num">{e.row_no === 0 ? 'File' : e.row_no}</td>
                        <td>{e.column_name ?? '—'}</td>
                        <td dir="auto">{e.reason}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              {errCount > errors.length && <div className="muted" style={{ padding: 10 }}>Showing first {errors.length} of {errCount}.</div>}
            </div>
          </div>
        )}
      </div>
    </>
  );
}
