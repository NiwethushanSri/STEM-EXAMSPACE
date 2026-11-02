import { AppShell } from "@/components/AppShell";
import { PaperUpload } from "@/components/PaperUpload";

export default function UploadPapers() {
  return (
    <AppShell role="admin" title="Upload student papers">
      <PaperUpload />
    </AppShell>
  );
}
