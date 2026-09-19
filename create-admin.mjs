/**
 * Creates the first administrator, or changes an existing one's role.
 *
 *   node --env-file=.env.local scripts/create-admin.mjs \
 *     "finance@msri.online" "Strong-Passphrase" "Tshidiso Gama" super_admin
 *
 * Uses the service role key, so run it from a trusted machine only.
 */
import { createClient } from "@supabase/supabase-js";

const [email, password, fullName, role = "super_admin"] = process.argv.slice(2);

if (!email || !password || !fullName) {
  console.error('Usage: create-admin.mjs "email" "password" "Full Name" [role]');
  process.exit(1);
}
if (password.length < 12) {
  console.error("Use a password of at least 12 characters.");
  process.exit(1);
}
const roles = ["super_admin", "finance_admin", "course_admin", "viewer"];
if (!roles.includes(role)) {
  console.error(`Role must be one of: ${roles.join(", ")}`);
  process.exit(1);
}

const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !key) {
  console.error("NEXT_PUBLIC_SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set.");
  process.exit(1);
}

const sb = createClient(url, key, { auth: { persistSession: false } });

let userId;
const created = await sb.auth.admin.createUser({
  email, password, email_confirm: true,
});

if (created.error) {
  if (!/already/i.test(created.error.message)) {
    console.error(created.error.message);
    process.exit(1);
  }
  const { data } = await sb.auth.admin.listUsers({ perPage: 1000 });
  userId = data.users.find((u) => u.email?.toLowerCase() === email.toLowerCase())?.id;
  if (!userId) { console.error("The account exists but could not be found."); process.exit(1); }
  console.log("Account already existed. Updating its role.");
} else {
  userId = created.data.user.id;
}

const { error } = await sb.from("app_users").upsert({
  id: userId, email, full_name: fullName, role, is_active: true,
}, { onConflict: "id" });

if (error) { console.error(error.message); process.exit(1); }

await sb.from("audit_logs").insert({
  actor_email: email, action: "user.created", entity_type: "user", entity_id: userId,
  summary: `Administrator ${email} set to ${role}`,
});

console.log(`Done. ${email} can sign in as ${role}.`);
