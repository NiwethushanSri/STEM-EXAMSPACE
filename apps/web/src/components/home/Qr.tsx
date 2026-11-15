import QRCode from "qrcode";

/** A QR code drawn as SVG, encoded synchronously so the section around it stays static. */
export function QrSvg({ text, className, label = "Example QR code" }: { text: string; className?: string; label?: string }) {
  const { size, data } = QRCode.create(text, { errorCorrectionLevel: "M" }).modules;
  let d = "";
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) if (data[y * size + x]) d += `M${x + 1} ${y + 1}h1v1h-1z`;
  return (
    <svg viewBox={`0 0 ${size + 2} ${size + 2}`} className={className} role="img" aria-label={label} shapeRendering="crispEdges">
      <rect width={size + 2} height={size + 2} fill="#ffffff" />
      <path d={d} fill="#10224f" />
    </svg>
  );
}
