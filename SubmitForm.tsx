"use client";

import { useState, useTransition } from "react";
import { submitPop, type SubmitResult } from "./actions";
import { PAYMENT_METHODS } from "@/lib/types";

export function SubmitForm() {
  const [result, setResult] = useState<SubmitResult | null>(null);
  const [fileName, setFileName] = useState<string | null>(null);
  const [pending, start] = useTransition();

  function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const form = e.currentTarget;
    const fd = new FormData(form);
    start(async () => {
      const r = await submitPop(fd);
      setResult(r);
      if (r.ok) { form.reset(); setFileName(null); window.scrollTo({ top: 0 }); }
    });
  }

  if (result?.ok) {
    return (
      <div className="card">
        <div className="notice notice-ok" style={{ marginBottom: 14 }}>
          <strong>Received.</strong> Your proof of payment is with the finance office
          and is waiting to be verified.
        </div>
        <dl className="facts">
          <div><dt>Your reference</dt><dd><strong>{result.reference}</strong></dd></div>
          <div><dt>Participant</dt><dd>{result.name}</dd></div>
        </dl>
        <p className="faint" style={{ marginTop: 14 }}>
          Keep this reference. You will be contacted if anything is unclear.
        </p>
        <button className="btn" onClick={() => setResult(null)}>
          Submit another payment
        </button>
      </div>
    );
  }

  return (
    <form className="card" onSubmit={onSubmit}>
      {result?.error ? <div className="notice notice-error">{result.error}</div> : null}

      <div className="field">
        <label htmlFor="participant_ref">Participant ID</label>
        <input id="participant_ref" name="participant_ref" type="text" required
               placeholder="MSRI-001284" autoCapitalize="characters" autoComplete="off" />
        <p className="faint" style={{ marginTop: 4, marginBottom: 0 }}>
          On your registration letter, starting with MSRI.
        </p>
      </div>

      <div className="field-row">
        <div className="field">
          <label htmlFor="amount">Amount paid (R)</label>
          <input id="amount" name="amount" type="number" step="0.01" min="0.01"
                 inputMode="decimal" required placeholder="500.00" />
        </div>
        <div className="field">
          <label htmlFor="payment_date">Date paid</label>
          <input id="payment_date" name="payment_date" type="date" required
                 max={new Date().toISOString().slice(0, 10)} />
        </div>
      </div>

      <div className="field-row">
        <div className="field">
          <label htmlFor="method">How you paid</label>
          <select id="method" name="method" defaultValue="eft">
            {PAYMENT_METHODS.map((m) => <option key={m.value} value={m.value}>{m.label}</option>)}
          </select>
        </div>
        <div className="field">
          <label htmlFor="bank">Bank</label>
          <input id="bank" name="bank" type="text" placeholder="FNB" autoComplete="off" />
        </div>
      </div>

      <div className="field">
        <label htmlFor="reference">Payment reference</label>
        <input id="reference" name="reference" type="text" autoComplete="off"
               placeholder="The reference on your bank receipt" />
      </div>

      <div className="field">
        <label>Proof of payment</label>
        <div className="drop">
          <div>{fileName ?? "PDF, JPG or PNG, up to 10 MB"}</div>
          <input type="file" name="proof" required accept="application/pdf,image/jpeg,image/png"
                 onChange={(e) => setFileName(e.target.files?.[0]?.name ?? null)} />
        </div>
      </div>

      <button className="btn btn-primary" type="submit" disabled={pending}>
        {pending ? "Sending" : "Send proof of payment"}
      </button>
      <p className="faint" style={{ marginTop: 12, marginBottom: 0 }}>
        Your document is stored privately and is seen only by the finance office.
      </p>
    </form>
  );
}
