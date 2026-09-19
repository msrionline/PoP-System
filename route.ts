import { NextResponse } from "next/server";
import { supabaseServer } from "@/lib/supabase/server";
import { currentUser } from "@/lib/auth";

export async function GET(request: Request) {
  const user = await currentUser();
  if (!user) return NextResponse.json({ error: "Not signed in" }, { status: 401 });

  const q = (new URL(request.url).searchParams.get("q") ?? "").trim();
  if (q.length < 2) return NextResponse.json({ participants: [], payments: [] });

  const sb = await supabaseServer();
  const { data, error } = await sb.rpc("global_search", { p_query: q, p_limit: 8 });
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json(data);
}
