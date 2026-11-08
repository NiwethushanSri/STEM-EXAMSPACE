import { NextResponse } from "next/server";
import { readPaper } from "@/lib/paper-reader";
import { getSessionProfile } from "@/lib/supabase/server";

// Staff who work with papers. Route handlers cannot redirect like pages do, so the check answers 401/403.
const PAPER_ROLES = ["owner", "admin", "teacher", "tutor", "corrector"] as const;

export async function POST(request: Request) {
  const me = await getSessionProfile();
  if (!me) return NextResponse.json({ error: "Sign in to continue." }, { status: 401 });
  if (me.status !== "active" || !(PAPER_ROLES as readonly string[]).includes(me.role)) {
    return NextResponse.json({ error: "You do not have permission to do this." }, { status: 403 });
  }

  const form = await request.formData();
  const file = form.get("file");

  if (!(file instanceof File)) {
    return NextResponse.json({ error: "Send a PDF in the 'file' field." }, { status: 400 });
  }
  if (file.type !== "application/pdf" && !file.name.toLowerCase().endsWith(".pdf")) {
    return NextResponse.json({ error: "Only PDF files can be read." }, { status: 400 });
  }

  try {
    const bytes = new Uint8Array(await file.arrayBuffer());
    const reading = await readPaper(bytes);
    return NextResponse.json(reading);
  } catch {
    return NextResponse.json({ error: "This PDF could not be read." }, { status: 422 });
  }
}
