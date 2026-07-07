import React from 'react';
import ReactDOM from 'react-dom/client';
import DemoBoard from './DemoBoard';
import './index.css';
import '@oybc/riso-tokens/riso.css'; // Riso design tokens + utilities (after index.css so its :root layers on)

// Initialize React app
ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <DemoBoard />
  </React.StrictMode>
);
