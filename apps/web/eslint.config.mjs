import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,
  // Override default ignores of eslint-config-next.
  globalIgnores([
    // Default ignores of eslint-config-next:
    ".next/**",
    "out/**",
    "build/**",
    "next-env.d.ts",
    // Vendored third-party bundle.
    "public/pdf.worker.mjs",
  ]),
  // Legacy mockup, replaced in Parts 2-4. These files predate the current
  // lint rules and are exempted from two rules only, so CI stays green.
  // Remove each entry when its page is rebuilt.
  {
    files: [
      "src/app/admin/exams/page.tsx",
      "src/app/admin/notices/page.tsx",
      "src/app/examiner/papers/page.tsx",
      "src/app/parent/notices/page.tsx",
      "src/app/parent/page.tsx",
      "src/app/parent/results/page.tsx",
      "src/app/student/notices/page.tsx",
      "src/app/student/page.tsx",
      "src/app/student/papers/page.tsx",
      "src/app/student/timetable/page.tsx",
      "src/components/AlertsPanel.tsx",
      "src/components/PaperMarking.tsx",
      "src/components/PaperUpload.tsx",
      "src/components/PdfViewer.tsx",
      "src/components/ProgressReport.tsx",
    ],
    rules: {
      "react-hooks/set-state-in-effect": "off",
      "react/no-unescaped-entities": "off",
    },
  },
]);

export default eslintConfig;
