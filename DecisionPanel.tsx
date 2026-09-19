"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { decidePayment, addNote } from "../actions";
import { DECISIONS, REJECTION_REASONS, type PaymentStatus } from "@/lib/types";

export function DecisionPanel({
  paymentId, currentStatus, notes, readOnly,
}: {
  paymentId: string;
  currentStatus: PaymentStatus;
  notes: string | null;
  readOnly: boolean;
}) {
  const router = useRouter();
  const [decision, setDecision] = useState<PaymentStatus | "">("");
  const [reason, setReason] = useState("");
  const [reasonOther, setReasonOther] = useState("");
  const [note, setNote] = useState(notes ?? "");
  const [message, setMessage] = useState<{ tone: "ok" | "error"; text: string } | null>(null);
  const [pending, start] = useTransition();

  const needsReason = decision === "rejected";

  function save() {
    setMessage(null);
    start(async () => {
      const fd = new FormData();
      fd.set("payment_id", paymentId);
      fd.set("decision", decision);
      fd.set("reason", reason);
      fd.set("reason_other", reasonOther);
      fd.set("note", note);
      const result = await decidePayment(fd);
      if (result?.error) { setMessage({ tone: "error", text: result.error }); return; }
      setMessage({ tone: "ok", text: "Decision saved and recorded in the audit log." });
      setDecision("");
      router.refresh();
    });
  }

  function saveNoteOnly() {
    setMessage(null);
    start(async () => {
      const fd = new FormData();
      fd.set("payment_id", paymentId);
      fd.set("note", note);
      const result = await addNote(fd);
      setMessage(result?.error
        ? { tone: "error", text: result.error }
        : { tone: "ok", text: "Note saved." });
      router.refresh();
    });
  }

  if (readOnly) return null;

  return (
    <div className="card">
      <h2>Decision</h2>
      {message ? (
        <div className={`notice notice-${message.tone === "ok" ? "ok" : "error"}`}>{message.text}</div>
      ) : null}

      <div className="field">
        <label htmlFor="decision">What is the outcome?</label>
        <select id="decision" value={decision}
                onChange={(e) => setDecision(e.target.value as PaymentStatus)}>
          <option value="">Choose an outcome</option>
          {DECISIONS.filter((d) => d.value !== currentStatus).map((d) => (
            <option key={d.value} value={d.value}>{d.label}</option>
          ))}
        </select>
      </div>

      {needsReason ? (
        <>
          <div className="field">
            <label htmlFor="reason">Reason for rejection</label>
            <select id="reason" value={reason} onChange={(e) => setReason(e.target.value)}>
              <option value="">Choose a reason</option>
              {REJECTION_REASONS.map((r) => <option key={r} value={r}>{r}</option>)}
            </select>
          </div>
          {reason === "Other" ? (
            <div className="field">
              <label htmlFor="reason_other">Describe the reason</label>
              <input id="reason_other" type="text" value={reasonOther}
                     onChange={(e) => setReasonOther(e.target.value)} />
            </div>
          ) : null}
        </>
      ) : null}

      <div className="field">
        <label htmlFor="note">Administrator note</label>
        <textarea id="note" value={note} onChange={(e) => setNote(e.target.value)}
                  placeholder="What you checked, and against what. Visible to administrators only." />
      </div>

      <div className="btn-row">
        <button className={`btn ${decision === "rejected" ? "btn-danger" : "btn-primary"}`}
                onClick={save} disabled={pending || !decision}>
          {pending ? "Saving" : "Save decision"}
        </button>
        <button className="btn" onClick={saveNoteOnly} disabled={pending || !note.trim()}>
          Save note only
        </button>
      </div>
      <p className="faint" style={{ marginTop: 10, marginBottom: 0 }}>
        Only verified payments count towards a participant&apos;s paid total.
      </p>
    </div>
  );
}
