"use client";

import Link from "next/link";
import { Logo } from "@/components/Logo";
import { usePathname, useRouter } from "next/navigation";
import { createContext, useContext, useState, type ReactNode } from "react";
import { createClient } from "@/lib/supabase/client";

/** The signed-in user, provided once per staff area by its server layout (which has already checked the role). */
export type ShellUser = { name: string; roleLabel: string };
const ShellUserContext = createContext<ShellUser | null>(null);
export function ShellUserProvider({ user, children }: { user: ShellUser; children: ReactNode }) {
  return <ShellUserContext.Provider value={user}>{children}</ShellUserContext.Provider>;
}

/** Admin pages that still show sample data until their part of the build. */
function isPreviewPath(pathname: string) {
  return pathname.startsWith("/admin/") && !pathname.startsWith("/admin/accounts");
}

function SignOut() {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  return (
    <button
      type="button"
      disabled={busy}
      onClick={async () => {
        setBusy(true);
        await createClient().auth.signOut();
        router.replace("/login");
        router.refresh();
      }}
      className="rounded border border-blue-300 px-3 py-1 text-xs hover:bg-blue-600 disabled:opacity-60"
    >
      Sign out
    </button>
  );
}

export type NavItem = { href: string; label: string };

const roleNav: Record<string, { name: string; items: NavItem[] }> = {
  student: {
    name: "Student",
    items: [
      { href: "/student", label: "Dashboard" },
      { href: "/student/results", label: "Results" },
      { href: "/student/analysis", label: "Analysis & forecast" },
      { href: "/student/report", label: "Progress report" },
      { href: "/student/papers", label: "My papers" },
      { href: "/student/timetable", label: "Timetable" },
      { href: "/student/notices", label: "Notices" },
    ],
  },
  parent: {
    name: "Parent",
    items: [
      { href: "/parent", label: "Dashboard" },
      { href: "/parent/results", label: "Child's results" },
      { href: "/parent/report", label: "Progress report" },
      { href: "/parent/attendance", label: "Attendance" },
      { href: "/parent/notices", label: "Special notices" },
    ],
  },
  examiner: {
    name: "Examiner",
    items: [
      { href: "/examiner", label: "Worklist" },
      { href: "/examiner/papers", label: "Student papers" },
      { href: "/examiner/marking", label: "Marking" },
      { href: "/examiner/standardisation", label: "Standardisation" },
    ],
  },
  owner: {
    name: "Super administrator",
    items: [
      { href: "/owner", label: "Dashboard" },
      { href: "/owner/accounts", label: "Accounts" },
      { href: "/owner/staff", label: "Staff" },
    ],
  },
  teacher: { name: "Teacher", items: [{ href: "/teacher", label: "Home" }] },
  tutor: { name: "Tutor", items: [{ href: "/tutor", label: "Home" }] },
  corrector: { name: "Exam corrector", items: [{ href: "/corrector", label: "Home" }] },
  admin: {
    name: "Admin",
    items: [
      { href: "/admin", label: "Dashboard" },
      { href: "/admin/accounts", label: "Accounts" },
      { href: "/admin/exams", label: "Exams & timetable" },
      { href: "/admin/results", label: "Results sheets" },
      { href: "/admin/bookings", label: "Bookings & payments" },
      { href: "/admin/papers", label: "Paper allocation" },
      { href: "/admin/papers/upload", label: "Upload papers" },
      { href: "/admin/attendance", label: "Attendance" },
      { href: "/admin/marking", label: "Marking progress" },
      { href: "/admin/notices", label: "Notices" },
      { href: "/admin/audit", label: "Audit log" },
    ],
  },
};

export function AppShell({
  role,
  title,
  children,
}: {
  role: keyof typeof roleNav;
  title: string;
  children: ReactNode;
}) {
  const pathname = usePathname();
  const section = roleNav[role];
  const user = useContext(ShellUserContext);

  return (
    <div className="flex min-h-screen bg-slate-50 text-slate-900">
      <aside className="hidden w-60 shrink-0 flex-col bg-blue-700 text-white md:flex">
        <Link href="/" className="px-5 py-5">
          <Logo onDark className="h-12" />
        </Link>
        <p className="px-5 pb-3 text-xs uppercase tracking-wide text-blue-200">
          {section.name}
        </p>
        <nav className="flex flex-col gap-1 px-3">
          {section.items.map((item) => {
            const active = pathname === item.href;
            return (
              <Link
                key={item.href}
                href={item.href}
                className={`rounded px-3 py-2 text-sm transition ${
                  active ? "bg-white text-blue-700 font-medium" : "hover:bg-blue-600"
                }`}
              >
                {item.label}
              </Link>
            );
          })}
        </nav>
        {user && (
          <div className="mt-auto space-y-2 px-5 py-4 text-xs text-blue-100">
            <div>
              <div className="text-sm font-medium text-white">{user.name}</div>
              <div>{user.roleLabel}</div>
            </div>
            <SignOut />
          </div>
        )}
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="border-b border-slate-200 bg-white px-6 py-4">
          <div className="flex items-center justify-between">
            <h1 className="text-xl font-semibold text-slate-900">{title}</h1>
            <span className="flex items-center gap-3 text-sm text-slate-500">
              {user ? `${user.name} · ${user.roleLabel}` : `${section.name} view`}
              {user && (
                <span className="md:hidden">
                  <SignOut />
                </span>
              )}
            </span>
          </div>
          {/* Phone navigation: the sidebar is hidden below md */}
          <nav className="mt-3 flex gap-2 overflow-x-auto md:hidden">
            {section.items.map((item) => (
              <Link
                key={item.href}
                href={item.href}
                className={`shrink-0 rounded-full border px-3 py-1 text-xs ${
                  pathname === item.href
                    ? "border-blue-700 bg-blue-700 text-white"
                    : "border-slate-300 text-slate-700"
                }`}
              >
                {item.label}
              </Link>
            ))}
          </nav>
        </header>
        {isPreviewPath(pathname) && (
          <div role="note" className="border-b border-amber-200 bg-amber-50 px-6 py-2 text-sm text-amber-900">
            Preview — sample data. This page is not connected to live records yet.
          </div>
        )}
        <main className="flex-1 p-6">{children}</main>
      </div>
    </div>
  );
}

export function Card({ title, children }: { title?: string; children: ReactNode }) {
  return (
    <section aria-label={title} className="rounded-lg border border-slate-200 bg-white p-5 shadow-sm">
      {title && <h2 className="mb-3 text-sm font-semibold text-blue-800">{title}</h2>}
      {children}
    </section>
  );
}

export function Table({ head, rows }: { head: string[]; rows: (string | number | ReactNode)[][] }) {
  return (
    <div className="overflow-x-auto">
      <table className="w-full text-left text-sm">
        <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
          <tr>
            {head.map((h) => (
              <th key={h} className="py-2 pr-4 font-medium">
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row, i) => (
            <tr key={i} className="border-b border-slate-100 last:border-0">
              {row.map((cell, j) => (
                <td key={j} className="py-2.5 pr-4">
                  {cell}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function Stat({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="rounded-lg border border-slate-200 bg-white p-4 shadow-sm">
      <div className="text-xs uppercase tracking-wide text-slate-500">{label}</div>
      <div className="mt-1 text-2xl font-semibold text-blue-700">{value}</div>
    </div>
  );
}

export function Badge({ children, tone = "blue" }: { children: ReactNode; tone?: "blue" | "green" | "amber" | "red" | "slate" }) {
  const tones = {
    blue: "bg-blue-100 text-blue-800",
    green: "bg-green-100 text-green-800",
    amber: "bg-amber-100 text-amber-800",
    red: "bg-red-100 text-red-800",
    slate: "bg-slate-200 text-slate-700",
  };
  return <span className={`rounded-full px-2 py-0.5 text-xs font-medium ${tones[tone]}`}>{children}</span>;
}
