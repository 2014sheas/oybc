import type { SVGProps } from 'react';

/**
 * The Riso stroke-icon set — inline SVGs that inherit `currentColor` via
 * `stroke`. Ported from the handoff prototype's `icons.jsx` so the web Riso
 * surfaces share one icon vocabulary (the iOS side uses SF Symbols). Grows as
 * later phases need more glyphs.
 */
export type RisoIconName =
  | 'boards'
  | 'home'
  | 'tasks'
  | 'you'
  | 'plus'
  | 'back'
  | 'check'
  | 'sun'
  | 'moon'
  | 'share'
  | 'sync'
  | 'sliders'
  | 'repeat'
  | 'grid'
  | 'flame'
  | 'shield'
  | 'bell'
  | 'logout'
  | 'chevron'
  | 'edit'
  | 'trash'
  | 'dots';

const PATHS: Record<RisoIconName, React.ReactNode> = {
  boards: (
    <>
      <rect x="3" y="3" width="7" height="7" rx="1.4" />
      <rect x="14" y="3" width="7" height="7" rx="1.4" />
      <rect x="3" y="14" width="7" height="7" rx="1.4" />
      <rect x="14" y="14" width="7" height="7" rx="1.4" />
    </>
  ),
  home: (
    <>
      <path d="M4 11l8-7 8 7" />
      <path d="M6 10v9h12v-9" />
    </>
  ),
  tasks: (
    <>
      <line x1="8" y1="6" x2="20" y2="6" />
      <line x1="8" y1="12" x2="20" y2="12" />
      <line x1="8" y1="18" x2="20" y2="18" />
      <circle cx="4" cy="6" r="1.3" />
      <circle cx="4" cy="12" r="1.3" />
      <circle cx="4" cy="18" r="1.3" />
    </>
  ),
  you: (
    <>
      <circle cx="12" cy="8" r="4" />
      <path d="M4 21c0-4 3.5-6 8-6s8 2 8 6" />
    </>
  ),
  plus: (
    <>
      <line x1="12" y1="5" x2="12" y2="19" />
      <line x1="5" y1="12" x2="19" y2="12" />
    </>
  ),
  back: <polyline points="15 18 9 12 15 6" />,
  check: <polyline points="4 12 9 17 20 6" />,
  sun: (
    <>
      <circle cx="12" cy="12" r="4" />
      <line x1="12" y1="2" x2="12" y2="4" />
      <line x1="12" y1="20" x2="12" y2="22" />
      <line x1="4" y1="12" x2="2" y2="12" />
      <line x1="22" y1="12" x2="20" y2="12" />
      <line x1="5" y1="5" x2="6.5" y2="6.5" />
      <line x1="17.5" y1="17.5" x2="19" y2="19" />
      <line x1="19" y1="5" x2="17.5" y2="6.5" />
      <line x1="6.5" y1="17.5" x2="5" y2="19" />
    </>
  ),
  moon: <path d="M21 12.8A8 8 0 1 1 11.2 3 6.3 6.3 0 0 0 21 12.8z" />,
  share: (
    <>
      <circle cx="6" cy="12" r="2.6" />
      <circle cx="17" cy="6" r="2.6" />
      <circle cx="17" cy="18" r="2.6" />
      <line x1="8.3" y1="10.8" x2="14.7" y2="7.2" />
      <line x1="8.3" y1="13.2" x2="14.7" y2="16.8" />
    </>
  ),
  sync: (
    <>
      <polyline points="21 4 21 10 15 10" />
      <polyline points="3 20 3 14 9 14" />
      <path d="M19 14a7 7 0 0 1-12 3M5 10a7 7 0 0 1 12-3" />
    </>
  ),
  sliders: (
    <>
      <line x1="4" y1="8" x2="20" y2="8" />
      <line x1="4" y1="16" x2="20" y2="16" />
      <circle cx="9" cy="8" r="2.2" />
      <circle cx="15" cy="16" r="2.2" />
    </>
  ),
  repeat: (
    <>
      <polyline points="17 2 21 6 17 10" />
      <path d="M3 11V9a4 4 0 0 1 4-4h14" />
      <polyline points="7 22 3 18 7 14" />
      <path d="M21 13v2a4 4 0 0 1-4 4H3" />
    </>
  ),
  grid: (
    <>
      <rect x="3" y="3" width="18" height="18" rx="2" />
      <line x1="9" y1="3" x2="9" y2="21" />
      <line x1="15" y1="3" x2="15" y2="21" />
      <line x1="3" y1="9" x2="21" y2="9" />
      <line x1="3" y1="15" x2="21" y2="15" />
    </>
  ),
  flame: <path d="M12 3c1 3 4 4 4 8a4 4 0 0 1-8 0c0-1.5.7-2.5 1.4-3.3C9 9 9 7 12 3z" />,
  shield: <path d="M12 3l7 3v5c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6z" />,
  bell: (
    <>
      <path d="M6 9a6 6 0 0 1 12 0c0 5 2 6 2 6H4s2-1 2-6z" />
      <path d="M10 19a2 2 0 0 0 4 0" />
    </>
  ),
  logout: (
    <>
      <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" />
      <polyline points="16 17 21 12 16 7" />
      <line x1="21" y1="12" x2="9" y2="12" />
    </>
  ),
  chevron: <polyline points="9 6 15 12 9 18" />,
  edit: (
    <>
      <path d="M4 20h4l10-10-4-4L4 16z" />
      <line x1="13" y1="7" x2="17" y2="11" />
    </>
  ),
  trash: (
    <>
      <polyline points="4 7 20 7" />
      <path d="M7 7v12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2V7" />
      <path d="M9 7V5a2 2 0 0 1 2-2h2a2 2 0 0 1 2 2v2" />
    </>
  ),
  dots: (
    <>
      <circle cx="5" cy="12" r="1.6" />
      <circle cx="12" cy="12" r="1.6" />
      <circle cx="19" cy="12" r="1.6" />
    </>
  ),
};

export interface RisoIconProps extends Omit<SVGProps<SVGSVGElement>, 'name'> {
  /** Which glyph to render. */
  name: RisoIconName;
  /** Pixel size (width = height). Defaults to inheriting via CSS if omitted. */
  size?: number;
}

/**
 * Render a Riso stroke icon. Stroke inherits `currentColor`; set width via
 * `size` or CSS. Decorative by default (`aria-hidden`) — pass an `aria-label`
 * to make it meaningful to assistive tech.
 */
export function RisoIcon({ name, size, 'aria-label': ariaLabel, ...rest }: RisoIconProps): React.ReactElement {
  return (
    <svg
      viewBox="0 0 24 24"
      width={size}
      height={size}
      fill="none"
      stroke="currentColor"
      strokeWidth={2.1}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden={ariaLabel ? undefined : true}
      aria-label={ariaLabel}
      role={ariaLabel ? 'img' : undefined}
      {...rest}
    >
      {PATHS[name]}
    </svg>
  );
}
