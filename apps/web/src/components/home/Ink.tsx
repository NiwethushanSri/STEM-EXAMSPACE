import type { ReactNode } from "react";
import s from "./home.module.css";

/** The marker's red pen on the example script. Plain components, usable on server and client. */

export function RedTick({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 40 28" width="36" height="25" aria-hidden="true" className={className ?? s.redTick}>
      <path d="M4 15c4 3 7 7 9 10C18 15 26 7 37 3" fill="none" stroke="#c8261b" strokeWidth="3.4" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

export function RedRing({ children }: { children: ReactNode }) {
  return (
    <span className={s.redRing}>
      {children}
      <svg viewBox="0 0 80 40" preserveAspectRatio="none" aria-hidden="true">
        <path d="M8 22C6 9 30 3 52 5s26 10 22 20-30 13-48 10S8 26 12 16" fill="none" stroke="#c8261b" strokeWidth="2.6" strokeLinecap="round" />
      </svg>
    </span>
  );
}
