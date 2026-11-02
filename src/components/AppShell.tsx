"use client";

import Link from "next/link";
import { Logo } from "@/components/Logo";
import { usePathname } from "next/navigation";
import type { ReactNode } from "react";

export type NavItem = { href: string; label: string };

const roleNav: Record<string, { name: string; items: NavItem[] }> = {
  student: {
    name: "Student",
    items: [
      { href: "/student", label: "Dashboard" },
      { href: "/student/results", label: "Results" },
      { href: "/student/analysis", label: "Analysis & forecast" },
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
        <div className="mt-auto px-5 py-4 text-xs text-blue-200">
          <Link href="/login" className="hover:text-white">
            Switch role
          </Link>
        </div>
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="border-b border-slate-200 bg-white px-6 py-4">
          <div className="flex items-center justify-between">
            <h1 className="text-xl font-semibold text-slate-900">{title}</h1>
            <span className="text-sm text-slate-500">{section.name} view</span>
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
        <main className="flex-1 p-6">{children}</main>
      </div>
    </div>
  );
}

export function Card({ title, children }: { title?: string; children: ReactNode }) {
  return (
    <section className="rounded-lg border border-slate-200 bg-white p-5 shadow-sm">
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
