"use client";

import { useState, useTransition } from "react";
import { validateImport, commitImport, type ImportReport } from "./actions";
import { formatNumber } from "@/lib/format";

export function ImportPanel() {
  const [report, setReport] = useState<ImportReport | null>(null);
  const [done, setDone] = useState<number | null>(null);
  const [pending, start] = useTransition();

  function check(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const fd = new FormData(e.currentTarget);
    setDone(null);
    start(async () => setReport(await validateImport(fd)));
  }

  function commit() {
    if (!report?.valid.length) return;
    start(async () => {
      const r = await commitImport(JSON.stringify(report.valid));
      setDone(r.imported ?? 0);
      setReport(r.error ? { ...report, error: r.error } : null);
    });
  }

  return (
    <>
      {done !== null ? (
        <div className="notice notice-ok">
          {formatNumber(done)} participants imported. They appear in the participant list immediately.
        </div>
      ) : null}

      <div className="grid grid-2">
        <form className="card" onSubmit={check}>
          <h2>Choose your file</h2>
          {report?.error ? <div className="notice notice-error">{report.error}</div> : null}
          <div className="field">
            <label htmlFor="file">CSV file</label>
            <input id="file" name="file" type="file" accept=".csv,text/csv" required />
          </div>
          <button className="btn btn-primary" type="submit" disabled={pending}>
            {pending ? "Checking" : "Check file"}
          </button>
        </form>

        <div className="card">
          <h2>Expected columns</h2>
          <p className="faint">
            First row must be a header. participant_id, cohort_code and amount_due are optional:
            a participant ID is generated when blank, and amount due falls back to the programme fee.
          </p>
          <pre style={{ background: "var(--surface)", padding: 12, borderRadius: 6, overflowX: "auto", fontSize: "0.8125rem" }}>
{`participant_id,first_name,surname,email,mobile,programme_code,cohort_code,amount_due
,Thandi,Nkosi,thandi@example.co.za,0721234567,HC-AIS,2026-S1,12000
MSRI-004120,Sipho,Dlamini,sipho@example.co.za,0731234567,SP-MASTER,,2000`}
          </pre>
        </div>
      </div>

      {report && !report.error ? (
        <div className="card" style={{ marginTop: 14 }}>
          <h2>Check result</h2>
          <div className="grid grid-4" style={{ marginBottom: 14 }}>
            <div className="stat"><div className="label">Rows detected</div><div className="value">{formatNumber(report.detected)}</div></div>
            <div className="stat"><div className="label">Ready to import</div><div className="value">{formatNumber(report.valid.length)}</div></div>
            <div className="stat flag"><div className="label">Already registered</div><div className="value">{formatNumber(report.duplicates.length)}</div></div>
            <div className="stat alert"><div className="label">Cannot be imported</div><div className="value">{formatNumber(report.invalid.length)}</div></div>
          </div>

          {report.invalid.length ? (
            <>
              <h3>Rows with problems</h3>
              <div className="table-wrap" style={{ marginBottom: 14 }}>
                <table className="data">
                  <thead><tr><th>Line</th><th>Problem</th><th>Row</th></tr></thead>
                  <tbody>
                    {report.invalid.slice(0, 50).map((r) => (
                      <tr key={r.line}><td className="num">{r.line}</td><td>{r.problem}</td><td className="faint">{r.raw}</td></tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </>
          ) : null}

          {report.duplicates.length ? (
            <>
              <h3>Skipped as already registered</h3>
              <div className="table-wrap" style={{ marginBottom: 14 }}>
                <table className="data">
                  <thead><tr><th>Line</th><th>Participant</th><th>Reason</th></tr></thead>
                  <tbody>
                    {report.duplicates.slice(0, 50).map((r) => (
                      <tr key={`${r.line}-${r.participant_ref}`}>
                        <td className="num">{r.line}</td><td>{r.participant_ref}</td><td>{r.problem}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </>
          ) : null}

          <div className="btn-row">
            <button className="btn btn-primary" onClick={commit}
                    disabled={pending || !report.valid.length}>
              {pending ? "Importing" : `Import ${formatNumber(report.valid.length)} participants`}
            </button>
            <button className="btn" onClick={() => setReport(null)} disabled={pending}>Start over</button>
          </div>
          {report.invalid.length ? (
            <p className="faint" style={{ marginTop: 10, marginBottom: 0 }}>
              Rows with problems are left out. Fix them in the file and import that batch separately.
            </p>
          ) : null}
        </div>
      ) : null}
    </>
  );
}
