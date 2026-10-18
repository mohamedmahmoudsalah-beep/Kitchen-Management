// تجهيز النص العربي لـ PDF: jsPDF مبيعملش shaping ولا ترتيب RTL، فبنعمله إحنا (arabic-reshaper + bidi-js)
import ArabicReshaper from 'arabic-reshaper';
import bidiFactory from 'bidi-js';

const bidi = bidiFactory();

// خط Cairo مفيهوش أشكال "المنفصل" (isolated) في Presentation Forms-B، فبنرجّعها للحرف الأساسي (اللي موجود في الخط)
const ISOLATED_FALLBACK: Record<string, string> = {
  '\uFB50': '\u0671',
  '\uFB56': '\u067E',
  '\uFB66': '\u0679',
  '\uFB6A': '\u06A4',
  '\uFB7A': '\u0686',
  '\uFB88': '\u0688',
  '\uFB8A': '\u0698',
  '\uFB8C': '\u0691',
  '\uFB8E': '\u06A9',
  '\uFB92': '\u06AF',
  '\uFB9E': '\u06BA',
  '\uFBA6': '\u06C1',
  '\uFBAA': '\u06BE',
  '\uFBAE': '\u06D2',
  '\uFBB0': '\u06D3',
  '\uFBEA': '\u0626\u0627',
  '\uFBEE': '\u0626\u0648',
  '\uFBF9': '\u0626\u0649',
  '\uFBFC': '\u06CC',
  '\uFC00': '\u0626\u062C',
  '\uFC01': '\u0626\u062D',
  '\uFC02': '\u0626\u0645',
  '\uFC03': '\u0626\u0649',
  '\uFC04': '\u0626\u064A',
  '\uFC05': '\u0628\u062C',
  '\uFC06': '\u0628\u062D',
  '\uFC07': '\u0628\u062E',
  '\uFC08': '\u0628\u0645',
  '\uFC09': '\u0628\u0649',
  '\uFC0A': '\u0628\u064A',
  '\uFC0B': '\u062A\u062C',
  '\uFC0C': '\u062A\u062D',
  '\uFC0D': '\u062A\u062E',
  '\uFC0E': '\u062A\u0645',
  '\uFC0F': '\u062A\u0649',
  '\uFC10': '\u062A\u064A',
  '\uFC11': '\u062B\u062C',
  '\uFC12': '\u062B\u0645',
  '\uFC13': '\u062B\u0649',
  '\uFC14': '\u062B\u064A',
  '\uFC15': '\u062C\u062D',
  '\uFC16': '\u062C\u0645',
  '\uFC17': '\u062D\u062C',
  '\uFC18': '\u062D\u0645',
  '\uFC19': '\u062E\u062C',
  '\uFC1A': '\u062E\u062D',
  '\uFC1B': '\u062E\u0645',
  '\uFC1C': '\u0633\u062C',
  '\uFC1D': '\u0633\u062D',
  '\uFC1E': '\u0633\u062E',
  '\uFC1F': '\u0633\u0645',
  '\uFC20': '\u0635\u062D',
  '\uFC21': '\u0635\u0645',
  '\uFC22': '\u0636\u062C',
  '\uFC23': '\u0636\u062D',
  '\uFC24': '\u0636\u062E',
  '\uFC25': '\u0636\u0645',
  '\uFC26': '\u0637\u062D',
  '\uFC27': '\u0637\u0645',
  '\uFC28': '\u0638\u0645',
  '\uFC29': '\u0639\u062C',
  '\uFC2A': '\u0639\u0645',
  '\uFC2B': '\u063A\u062C',
  '\uFC2C': '\u063A\u0645',
  '\uFC2D': '\u0641\u062C',
  '\uFC2E': '\u0641\u062D',
  '\uFC2F': '\u0641\u062E',
  '\uFC30': '\u0641\u0645',
  '\uFC31': '\u0641\u0649',
  '\uFC32': '\u0641\u064A',
  '\uFC33': '\u0642\u062D',
  '\uFC34': '\u0642\u0645',
  '\uFC35': '\u0642\u0649',
  '\uFC36': '\u0642\u064A',
  '\uFC37': '\u0643\u0627',
  '\uFC38': '\u0643\u062C',
  '\uFC39': '\u0643\u062D',
  '\uFC3A': '\u0643\u062E',
  '\uFC3B': '\u0643\u0644',
  '\uFC3C': '\u0643\u0645',
  '\uFC3D': '\u0643\u0649',
  '\uFC3E': '\u0643\u064A',
  '\uFC3F': '\u0644\u062C',
  '\uFC40': '\u0644\u062D',
  '\uFC41': '\u0644\u062E',
  '\uFC42': '\u0644\u0645',
  '\uFC45': '\u0645\u062C',
  '\uFC46': '\u0645\u062D',
  '\uFC47': '\u0645\u062E',
  '\uFC48': '\u0645\u0645',
  '\uFC49': '\u0645\u0649',
  '\uFC4A': '\u0645\u064A',
  '\uFC4B': '\u0646\u062C',
  '\uFC4C': '\u0646\u062D',
  '\uFC4D': '\u0646\u062E',
  '\uFC4E': '\u0646\u0645',
  '\uFC4F': '\u0646\u0649',
  '\uFC50': '\u0646\u064A',
  '\uFC51': '\u0647\u062C',
  '\uFC52': '\u0647\u0645',
  '\uFC53': '\u0647\u0649',
  '\uFC54': '\u0647\u064A',
  '\uFC55': '\u064A\u062C',
  '\uFC56': '\u064A\u062D',
  '\uFC57': '\u064A\u062E',
  '\uFC58': '\u064A\u0645',
  '\uFC59': '\u064A\u0649',
  '\uFC5A': '\u064A\u064A',
  '\uFC5B': '\u0630\u0670',
  '\uFC5C': '\u0631\u0670',
  '\uFC5D': '\u0649\u0670',
  '\uFC5E': '\u0020\u064C\u0651',
  '\uFC5F': '\u0020\u064D\u0651',
  '\uFC60': '\u0020\u064E\u0651',
  '\uFC61': '\u0020\u064F\u0651',
  '\uFC62': '\u0020\u0650\u0651',
  '\uFC63': '\u0020\u0651\u0670',
  '\uFCF5': '\u0637\u0649',
  '\uFCF6': '\u0637\u064A',
  '\uFCF7': '\u0639\u0649',
  '\uFCF8': '\u0639\u064A',
  '\uFCF9': '\u063A\u0649',
  '\uFCFA': '\u063A\u064A',
  '\uFCFF': '\u062D\u0649',
  '\uFD00': '\u062D\u064A',
  '\uFD01': '\u062C\u0649',
  '\uFD02': '\u062C\u064A',
  '\uFD03': '\u062E\u0649',
  '\uFD04': '\u062E\u064A',
  '\uFD09': '\u0634\u062C',
  '\uFD0A': '\u0634\u062D',
  '\uFD0B': '\u0634\u062E',
  '\uFD0C': '\u0634\u0645',
  '\uFD3D': '\u0627\u064B',
  '\uFDF0': '\u0635\u0644\u06D2',
  '\uFDF1': '\u0642\u0644\u06D2',
  '\uFDF3': '\u0627\u0643\u0628\u0631',
  '\uFDF4': '\u0645\u062D\u0645\u062F',
  '\uFDF5': '\u0635\u0644\u0639\u0645',
  '\uFDF6': '\u0631\u0633\u0648\u0644',
  '\uFDF7': '\u0639\u0644\u064A\u0647',
  '\uFDF8': '\u0648\u0633\u0644\u0645',
  '\uFDF9': '\u0635\u0644\u0649',
  '\uFDFA': '\u0635\u0644\u0649\u0020\u0627\u0644\u0644\u0647\u0020\u0639\u0644\u064A\u0647\u0020\u0648\u0633\u0644\u0645',
  '\uFDFB': '\u062C\u0644\u0020\u062C\u0644\u0627\u0644\u0647',
  '\uFDFC': '\u0631\u06CC\u0627\u0644',
  '\uFE70': '\u0020\u064B',
  '\uFE72': '\u0020\u064C',
  '\uFE74': '\u0020\u064D',
  '\uFE76': '\u0020\u064E',
  '\uFE78': '\u0020\u064F',
  '\uFE7A': '\u0020\u0650',
  '\uFE7C': '\u0020\u0651',
  '\uFE7E': '\u0020\u0652',
  '\uFE80': '\u0621',
  '\uFE81': '\u0622',
  '\uFE83': '\u0623',
  '\uFE85': '\u0624',
  '\uFE87': '\u0625',
  '\uFE89': '\u0626',
  '\uFE8D': '\u0627',
  '\uFE8F': '\u0628',
  '\uFE93': '\u0629',
  '\uFE95': '\u062A',
  '\uFE99': '\u062B',
  '\uFE9D': '\u062C',
  '\uFEA1': '\u062D',
  '\uFEA5': '\u062E',
  '\uFEA9': '\u062F',
  '\uFEAB': '\u0630',
  '\uFEAD': '\u0631',
  '\uFEAF': '\u0632',
  '\uFEB1': '\u0633',
  '\uFEB5': '\u0634',
  '\uFEB9': '\u0635',
  '\uFEBD': '\u0636',
  '\uFEC1': '\u0637',
  '\uFEC5': '\u0638',
  '\uFEC9': '\u0639',
  '\uFECD': '\u063A',
  '\uFED1': '\u0641',
  '\uFED5': '\u0642',
  '\uFED9': '\u0643',
  '\uFEDD': '\u0644',
  '\uFEE1': '\u0645',
  '\uFEE5': '\u0646',
  '\uFEE9': '\u0647',
  '\uFEED': '\u0648',
  '\uFEEF': '\u0649',
  '\uFEF1': '\u064A',
};

const ARABIC = /[\u0600-\u06FF\u0750-\u077F\uFB50-\uFDFF\uFE70-\uFEFF]/;
const STRONG_LTR = /[A-Za-z\u00C0-\u024F]/;

export const hasArabic = (s: string) => ARABIC.test(s);

// أول حرف "قوي" بيحدد اتجاه الفقرة (زي الـ Unicode Bidi)
export function isRtlText(s: string): boolean {
  for (const ch of s) {
    if (ARABIC.test(ch)) return true;
    if (STRONG_LTR.test(ch)) return false;
  }
  return false;
}

// بيرجّع النص بالترتيب البصري (visual) من الشمال لليمين، جاهز يتكتب في PDF
export function shapeText(s: string): string {
  if (!s || !hasArabic(s)) return s;
  const reshaped = Array.from(ArabicReshaper.convertArabic(s)).map((c) => ISOLATED_FALLBACK[c] ?? c).join('');
  const levels = bidi.getEmbeddingLevels(reshaped, isRtlText(s) ? 'rtl' : 'ltr');
  const chars = Array.from(reshaped);
  // الأقواس وما شابه بتتعكس جوه الـ RTL
  const mirrored = bidi.getMirroredCharactersMap(reshaped, levels.levels);
  mirrored.forEach((ch: string, i: number) => { chars[i] = ch; });
  for (const [start, end] of bidi.getReorderSegments(reshaped, levels)) {
    const seg = chars.slice(start, end + 1).reverse();
    chars.splice(start, seg.length, ...seg);
  }
  return chars.join('');
}

// تقسيم نص "منطقي" لسطور بعرض محدد (القياس على النص المشكّل). التشكيل بيحصل بعد التقسيم لكل سطر لوحده.
export function wrapLogical(text: string, maxWidth: number, measure: (s: string) => number): string[] {
  const out: string[] = [];
  for (const para of String(text ?? '').split(/\r?\n/)) {
    const words = para.split(/\s+/).filter(Boolean);
    if (!words.length) { out.push(''); continue; }
    let line = '';
    const push = () => { if (line) out.push(line); line = ''; };
    for (const w of words) {
      const cand = line ? `${line} ${w}` : w;
      if (measure(shapeText(cand)) <= maxWidth) { line = cand; continue; }
      push();
      if (measure(shapeText(w)) <= maxWidth) { line = w; continue; }
      // كلمة أطول من العمود: نقطّعها حرف حرف
      let piece = '';
      for (const ch of Array.from(w)) {
        if (piece && measure(shapeText(piece + ch)) > maxWidth) { out.push(piece); piece = ch; } else piece += ch;
      }
      line = piece;
    }
    push();
  }
  return out.length ? out : [''];
}
