// بيظهر فورًا وإنت بتنقل بين الصفحات (بدل ما الشاشة تبان معلّقة)
export default function Loading() {
  return (
    <div className="skel" aria-busy="true" aria-label="Loading">
      <div className="skel-row">{[0, 1, 2, 3].map((i) => <div key={i} className="skel-box" style={{ height: 78 }} />)}</div>
      <div className="skel-box" style={{ height: 260 }} />
      <div className="skel-box" style={{ height: 180 }} />
    </div>
  );
}
