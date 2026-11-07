type IconName = "maths" | "further-maths" | "physics" | "chemistry" | "biology" | "computer-science" | "exam" | "chart" | "clock" | "shield";

// Simple line icons drawn in-house. Colour comes from the parent via currentColor.
export function SubjectIcon({ name, className = "h-8 w-8" }: { name: IconName; className?: string }) {
  const common = {
    viewBox: "0 0 24 24",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 1.8,
    strokeLinecap: "round" as const,
    strokeLinejoin: "round" as const,
    className,
    "aria-hidden": true,
  };

  switch (name) {
    case "maths":
      return (
        <svg {...common}>
          <rect x="5" y="3" width="14" height="18" rx="2" />
          <path d="M9 8h6M9 12h2M13 12h2M9 16h2M13 16h2" />
        </svg>
      );
    case "further-maths":
      return (
        <svg {...common}>
          <path d="M5 5h14l-7 7 7 7H5" />
        </svg>
      );
    case "physics":
      return (
        <svg {...common}>
          <circle cx="12" cy="12" r="2" />
          <ellipse cx="12" cy="12" rx="9" ry="4" />
          <ellipse cx="12" cy="12" rx="9" ry="4" transform="rotate(60 12 12)" />
          <ellipse cx="12" cy="12" rx="9" ry="4" transform="rotate(-60 12 12)" />
        </svg>
      );
    case "chemistry":
      return (
        <svg {...common}>
          <path d="M9 3h6M10 3v6l-5 9a2 2 0 0 0 2 3h10a2 2 0 0 0 2-3l-5-9V3" />
          <path d="M7.5 15h9" />
        </svg>
      );
    case "biology":
      return (
        <svg {...common}>
          <path d="M5 19c0-8 6-14 14-14 0 8-6 14-14 14z" />
          <path d="M5 19l8-8" />
        </svg>
      );
    case "computer-science":
      return (
        <svg {...common}>
          <rect x="3" y="4" width="18" height="12" rx="2" />
          <path d="M8 20h8M12 16v4M7 9l2 2-2 2M12 13h4" />
        </svg>
      );
    case "exam":
      return (
        <svg {...common}>
          <rect x="5" y="3" width="14" height="18" rx="2" />
          <path d="M9 9l2 2 4-4M9 15h6" />
        </svg>
      );
    case "chart":
      return (
        <svg {...common}>
          <path d="M4 20V4M4 20h16" />
          <path d="M8 16v-4M12 16V8M16 16v-6" />
        </svg>
      );
    case "clock":
      return (
        <svg {...common}>
          <circle cx="12" cy="12" r="9" />
          <path d="M12 7v5l3 2" />
        </svg>
      );
    case "shield":
      return (
        <svg {...common}>
          <path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6l8-3z" />
          <path d="M9 12l2 2 4-4" />
        </svg>
      );
  }
}
