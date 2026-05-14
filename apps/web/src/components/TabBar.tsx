import { NavLink } from 'react-router-dom';
import styles from './TabBar.module.css';

/**
 * TabBar — Bottom tab navigation for the production app.
 *
 * Four tabs: Boards (default), Tasks, Create, Profile.
 * Uses NavLink for automatic active state styling.
 *
 * Tab order rationale: Tasks sits adjacent to Boards so the
 * "what I'm working on" affordances are grouped on the left; Create
 * remains one tap away when the user wants to spin up a new board.
 */
export function TabBar(): React.ReactElement {
  return (
    <nav className={styles.tabbar} aria-label="Main navigation">
      <NavLink
        to="/boards"
        className={({ isActive }) =>
          `${styles.tabItem} ${isActive ? styles.tabItemActive : ''}`
        }
      >
        <span className={styles.tabIcon} aria-hidden="true">&#9638;</span>
        <span className={styles.tabLabel}>Boards</span>
      </NavLink>
      <NavLink
        to="/tasks"
        className={({ isActive }) =>
          `${styles.tabItem} ${isActive ? styles.tabItemActive : ''}`
        }
      >
        <span className={styles.tabIcon} aria-hidden="true">&#9776;</span>
        <span className={styles.tabLabel}>Tasks</span>
      </NavLink>
      <NavLink
        to="/create"
        className={({ isActive }) =>
          `${styles.tabItem} ${isActive ? styles.tabItemActive : ''}`
        }
      >
        <span className={styles.tabIcon} aria-hidden="true">&#43;</span>
        <span className={styles.tabLabel}>Create</span>
      </NavLink>
      <NavLink
        to="/profile"
        className={({ isActive }) =>
          `${styles.tabItem} ${isActive ? styles.tabItemActive : ''}`
        }
      >
        <span className={styles.tabIcon} aria-hidden="true">&#9679;</span>
        <span className={styles.tabLabel}>Profile</span>
      </NavLink>
    </nav>
  );
}
