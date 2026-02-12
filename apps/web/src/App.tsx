import { useEffect, useState } from 'react';
import { BrowserRouter, Routes, Route } from 'react-router-dom';
import { Navbar } from './components/Navbar';
import { Home } from './pages/Home';
import { Playground } from './pages/Playground';

/**
 * Theme type
 */
type Theme = 'light' | 'dark';

/**
 * Local storage key for theme preference
 */
const THEME_STORAGE_KEY = 'oybc-theme';

/**
 * Main App Component
 *
 * Root component for the OYBC web app.
 * Manages routing, theme state, and persists theme preference to localStorage.
 */
function App() {
  // Initialize theme from localStorage or default to 'light'
  const [theme, setTheme] = useState<Theme>(() => {
    const savedTheme = localStorage.getItem(THEME_STORAGE_KEY);
    return (savedTheme === 'dark' ? 'dark' : 'light') as Theme;
  });

  // Apply theme to document root
  useEffect(() => {
    document.documentElement.setAttribute('data-theme', theme);
    localStorage.setItem(THEME_STORAGE_KEY, theme);
  }, [theme]);

  /**
   * Toggle between light and dark themes
   */
  const toggleTheme = () => {
    setTheme((prev) => (prev === 'light' ? 'dark' : 'light'));
  };

  return (
    <BrowserRouter>
      <Navbar theme={theme} onThemeToggle={toggleTheme} />
      <Routes>
        <Route path="/" element={<Home />} />
        <Route path="/playground" element={<Playground />} />
      </Routes>
    </BrowserRouter>
  );
}

export default App;
