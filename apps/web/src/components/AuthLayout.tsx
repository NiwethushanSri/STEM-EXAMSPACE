import Link from "next/link";
import { Logo } from "@/components/Logo";
import type { ReactNode } from "react";

export function AuthLayout({
  title,
  subtitle,
  children,
  footer,
}: {
  title: string;
  subtitle: string;
  children: ReactNode;
  footer: ReactNode;
}) {
  return (
    <div className="min-h-screen bg-slate-50 lg:grid lg:grid-cols-2">
      {/* Brand panel */}
      <aside className="relative hidden overflow-hidden bg-gradient-to-br from-blue-700 via-blue-600 to-sky-500 text-white lg:flex lg:flex-col lg:justify-between lg:p-12">
        <div className="pointer-events-none absolute -right-20 -top-20 h-80 w-80 rounded-full bg-white/10" />
        <div className="pointer-events-none absolute -bottom-24 -left-16 h-72 w-72 rounded-full bg-white/10" />
        <Link href="/" className="relative">
          <Logo onDark className="h-14" />
        </Link>
        <div className="relative">
          <h2 className="text-3xl font-semibold leading-tight">Practise like the real exam. Learn from every result.</h2>
          <ul className="mt-6 space-y-3 text-blue-50">
            <li className="flex gap-3"><span className="mt-2 h-2 w-2 shrink-0 rounded-full bg-amber-300" />Marks and feedback by question</li>
            <li className="flex gap-3"><span className="mt-2 h-2 w-2 shrink-0 rounded-full bg-amber-300" />Forecasts that show where you are heading</li>
            <li className="flex gap-3"><span className="mt-2 h-2 w-2 shrink-0 rounded-full bg-amber-300" />One place for students, parents and teachers</li>
          </ul>
        </div>
        <img src="/images/hero-stem.svg" alt="" className="relative mx-auto w-4/5 drop-shadow-2xl" />
      </aside>

      {/* Form */}
      <main className="flex min-h-screen flex-col items-center justify-center px-6 py-12">
        <Link href="/" className="mb-8 lg:hidden">
          <Logo className="h-14" />
        </Link>
        <div className="w-full max-w-md rounded-2xl bg-white p-8 shadow-xl ring-1 ring-slate-100">
          <h1 className="text-2xl font-semibold text-slate-900">{title}</h1>
          <p className="mt-1 text-sm text-slate-500">{subtitle}</p>
          <div className="mt-6">{children}</div>
        </div>
        <div className="mt-6 text-sm text-slate-600">{footer}</div>
      </main>
    </div>
  );
}

export const inputClass =
  "mt-1 w-full rounded-lg border border-slate-300 bg-white px-3 py-2.5 text-sm text-slate-900 placeholder:text-slate-400 focus:border-blue-600 focus:outline-none focus:ring-2 focus:ring-blue-100";

export const labelClass = "block text-sm font-medium text-slate-700";
