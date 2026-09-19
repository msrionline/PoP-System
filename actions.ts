"use server";

import { headers } from "next/headers";
import { supabaseAdmin } from "@/lib/supabase/admin";
import { rateLimit } from "@/lib/rate-limit";
import { validateUpload, sha256, storagePath, MAX_UPLOAD_BYTES } from "@/lib/upload";

export interface SubmitResult {
  ok?: boolean;
  reference?: string;
  name?: string;
  error?: string;
}

/** Public submission. Runs with the service role because the participant has
 *  no account, so every field is treated as untrusted: the participant must
 *  already exist, the file is checked by its bytes rather than its name, and
 *  the record is written by a single database function. */
export async function submitPop(formData: FormData): Promise<SubmitResult> {
  const h = await headers();
  const ip = (h.get("x-forwarded-for") ?? "unknown").split(",")[0].trim();
  if (!rateLimit(`pop:${ip}`, 8, 60_000).allowed)
    return { error: "Too many submissions from this device. Wait a minute and try again." };

  const participantRef = String(formData.get("participant_ref") ?? "").trim().toUpperCase();
  const amount = Number(formData.get("amount"));
  const paymentDate = String(formData.get("payment_date") ?? "");
  const reference = String(formData.get("reference") ?? "").trim();
  const method = String(formData.get("method") ?? "eft");
  const bank = String(formData.get("bank") ?? "").trim();
  const file = formData.get("proof");

  if (!participantRef) return { error: "Enter your participant ID, for example MSRI-001284." };
  if (!Number.isFinite(amount) || amount <= 0) return { error: "Enter the amount you paid." };
  if (!paymentDate) return { error: "Enter the date the payment was made." };
  if (new Date(paymentDate) > new Date())
    return { error: "The payment date cannot be in the future." };
  if (!(file instanceof File) || file.size === 0)
    return { error: "Attach your proof of payment as a PDF, JPG or PNG." };
  if (file.size > MAX_UPLOAD_BYTES)
    return { error: "The file is larger than 10 MB. Send a smaller copy." };

  const bytes = new Uint8Array(await file.arrayBuffer());
  const invalid = validateUpload(file, bytes);
  if (invalid) return { error: invalid };

  const sb = supabaseAdmin();

  const { data: participant } = await sb
    .from("participants")
    .select("id, full_name")
    .eq("participant_ref", participantRef)
    .maybeSingle();

  // Same wording whether the ID is unknown or mistyped, so the form cannot be
  // used to discover which participant IDs exist.
  if (!participant)
    return { error: "That participant ID was not found. Check it against your registration letter." };

  const paymentId = crypto.randomUUID();
  const safeName = `proof-of-payment.${file.type === "application/pdf" ? "pdf" : file.type === "image/png" ? "png" : "jpg"}`;
  const path = storagePath(participant.id, paymentId, safeName);

  const { error: uploadError } = await sb.storage
    .from(process.env.POP_BUCKET ?? "proof-of-payment")
    .upload(path, bytes, { contentType: file.type, upsert: false });

  if (uploadError) return { error: "The file could not be uploaded. Try again in a moment." };

  const { data, error } = await sb.rpc("submit_payment", {
    p_participant_ref: participantRef,
    p_amount: amount,
    p_payment_date: paymentDate,
    p_reference: reference || null,
    p_method: method,
    p_bank: bank || null,
    p_storage_path: path,
    p_file_name: safeName,
    p_mime_type: file.type,
    p_file_size: file.size,
    p_file_hash: sha256(bytes),
    p_channel: "participant_portal",
  });

  if (error) {
    // Do not leave an orphaned object behind if the record could not be written.
    await sb.storage.from(process.env.POP_BUCKET ?? "proof-of-payment").remove([path]);
    if (error.message.includes("PARTICIPANT_NOT_FOUND"))
      return { error: "That participant ID was not found." };
    return { error: "The submission could not be recorded. Try again in a moment." };
  }

  const result = data as { payment_ref: string; participant_name: string };
  return { ok: true, reference: result.payment_ref, name: result.participant_name };
}
