import { NavLink } from 'react-router-dom';
import styles from './Navbar.module.css';

interface NavbarProps {
  theme: 'light' | 'dark';
  onThemeToggle: () => void;
}

/**
 * Navbar Component
 *
 * Provides navigation between Home and Playground, plus theme toggle.
 * Uses NavLink for automatic active state styling.
 */
export function Navbar({ theme, onThemeToggle }: NavbarProps) {
  return (
    <nav className={styles.navbar}>
      <div className={styles.navLinks}>
        <NavLink
          to="/"
          className={({ isActive }) =>
            `${styles.navLink} ${isActive ? styles.active : ''}`
          }
        >
          Home
        </NavLink>
        <NavLink
          to="/playground"
          className={({ isActive }) =>
            `${styles.navLink} ${isActive ? styles.active : ''}`
          }
        >
          Playground
        </NavLink>
      </div>

      <div className={styles.toolbar}>
        <button
          className={styles.themeToggle}
          onClick={onThemeToggle}
          aria-label="Toggle theme"
        >
          {theme === 'light' ? '🌙 Dark' : '☀️ Light'}
        </button>
      </div>
    </nav>
  );
}
