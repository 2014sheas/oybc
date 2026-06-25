import type { RisoIconName } from '../riso';

/** A primary navigation destination, shown in the top nav (desktop) and the
 *  bottom tab bar (mobile). */
export interface NavItem {
  label: string;
  path: string;
  icon: RisoIconName;
}

/**
 * The four primary tabs — Home · Boards · Tasks · You. "New board" is a
 * separate action button (not a tab) and "You" maps to the existing
 * `/profile` route. Shared by `AppTopNav` and `AppBottomNav` so the two stay
 * in lockstep.
 */
export const NAV_ITEMS: readonly NavItem[] = [
  { label: 'Home', path: '/home', icon: 'home' },
  { label: 'Boards', path: '/boards', icon: 'boards' },
  { label: 'Tasks', path: '/tasks', icon: 'tasks' },
  { label: 'You', path: '/profile', icon: 'you' },
];

/** Whether `path` is the active tab for the current `pathname` (exact, or a
 *  sub-route like `/boards/:id` / `/profile/board-preferences`). */
export function isNavItemActive(pathname: string, path: string): boolean {
  return pathname === path || pathname.startsWith(`${path}/`);
}
