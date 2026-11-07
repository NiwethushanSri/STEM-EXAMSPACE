import { NextResponse } from "next/server";
import { readPaper } from "@/lib/paper-reader";

export async function POST(request: Request) {
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
