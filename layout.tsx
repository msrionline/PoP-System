import Link from "next/link";
import { requireUser, canManageUsers } from "@/lib/auth";
import { supabaseServer } from "@/lib/supabase/server";
import { GlobalSearch } from "@/components/GlobalSearch";
import { SignOut } from "@/components/SignOut";
import { humanise } from "@/lib/format";
import { NavLink } from "@/components/NavLink";

export default async function AdminLayout({ children }: { children: React.ReactNode }) {
  const user = await requireUser();
  const sb = await supabaseServer();

  // Queue size sits in the navigation because it is the one number that tells
  // an administrator whether there is work waiting.
  const { count: queue } = await sb
    .from("payments")
    .select("id", { count: "exact", head: true })
    .in("status", ["pending_review", "under_review", "requires_clarification"]);

  return (
    <div className="shell">
      <aside className="sidebar">
        <div className="mark">
          <strong>Payments and PoP</strong>
          <span>MSR Learning Institute</span>
        </div>
        <nav>
          <NavLink href="/dashboard">Dashboard</NavLink>
          <NavLink href="/participants">Participants</NavLink>
          <NavLink href="/payments">Payments</NavLink>
          <NavLink href="/verification" count={queue ?? 0}>Verification</NavLink>
          <NavLink href="/programmes">Programmes</NavLink>
          <NavLink href="/reports">Reports</NavLink>
          <NavLink href="/import">Bulk import</NavLink>
          {canManageUsers(user) ? <NavLink href="/users">Users</NavLink> : null}
          <NavLink href="/audit">Audit log</NavLink>
          <NavLink href="/settings">Settings</NavLink>
        </nav>
        <div className="foot">
          {user.full_name}
          <br />
          {humanise(user.role)}
        </div>
      </aside>

      <div className="main">
        <header className="topbar">
          <GlobalSearch />
          <div style={{ marginLeft: "auto", display: "flex", gap: 8, alignItems: "center" }}>
            <Link className="btn btn-sm" href="/submit" target="_blank">Participant form</Link>
            <SignOut />
          </div>
        </header>
        <main className="content">{children}</main>
      </div>
    </div>
  );
}
