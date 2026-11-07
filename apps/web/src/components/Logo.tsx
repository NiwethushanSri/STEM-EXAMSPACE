// The Stem Examspace logo. On dark blue it sits on a white tile so the navy wordmark stays readable.
export function Logo({ className = "h-10", onDark = false }: { className?: string; onDark?: boolean }) {
  const image = <img src="/images/stem-examspace-logo.png" alt="Stem Examspace" className={`${className} w-auto`} />;
  if (!onDark) return image;
  return <span className="inline-block rounded-lg bg-white px-2 py-1.5 shadow-sm">{image}</span>;
}
