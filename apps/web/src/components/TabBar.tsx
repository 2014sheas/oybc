import { NavLink } from 'react-router-dom';
import styles from './TabBar.module.css';

/**
 * TabBar — Bottom tab navigation for the production app.
 *
 * Three tabs: Boards (default), Create, Profile.
 * Uses NavLink for automatic active state styling.
 */
export function TabBar(): React.ReactElement {
  return (
    <nav className={styles.tabbar}>
      <NavLink
        to="/boards"
        className={({ isActive }) =>
          `${styles.tabItem} ${isActive ? styles.tabItemActive : ''}`
        }
      >
        <span className={styles.tabIcon}>&#9638;</span>
        <span className={styles.tabLabel}>Boards</span>
      </NavLink>
      <NavLink
        to="/create"
        className={({ isActive }) =>
          `${styles.tabItem} ${isActive ? styles.tabItemActive : ''}`
        }
      >
        <span className={styles.tabIcon}>&#43;</span>
        <span className={styles.tabLabel}>Create</span>
      </NavLink>
      <NavLink
        to="/profile"
        className={({ isActive }) =>
          `${styles.tabItem} ${isActive ? styles.tabItemActive : ''}`
        }
      >
        <span className={styles.tabIcon}>&#9679;</span>
        <span className={styles.tabLabel}>Profile</span>
      </NavLink>
    </nav>
  );
}
