/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        // Brand — deep indigo. Reads as institutional rather than playful, and
        // stays legible printed in greyscale, which matters because half of
        // what this app produces goes to a printer.
        brand: {
          50: '#eef2ff',
          100: '#e0e7ff',
          200: '#c7d2fe',
          300: '#a5b4fc',
          400: '#818cf8',
          500: '#6366f1',
          600: '#4f46e5',
          700: '#4338ca',
          800: '#3730a3',
          900: '#312e81',
          950: '#1e1b4b',
        },
        // Money in. Never used for anything that is not a credit or a payment,
        // so "green on this screen" always means the same thing.
        money: {
          50: '#ecfdf5',
          100: '#d1fae5',
          // 200/300/800 were missing while several screens already used
          // border-money-200, border-money-300 and text-money-800 — Tailwind
          // emits nothing for an undefined shade, so those borders and that
          // text were simply invisible. Ramp completed rather than rewriting
          // the call sites to the shades that happened to exist.
          200: '#a7f3d0',
          300: '#6ee7b7',
          500: '#10b981',
          600: '#059669',
          700: '#047857',
          800: '#065f46',
          900: '#064e3b',
        },
        // Money owed / attention needed — not an error, just outstanding.
        due: {
          50: '#fffbeb',
          100: '#fef3c7',
          200: '#fde68a',
          300: '#fcd34d',
          500: '#f59e0b',
          600: '#d97706',
          700: '#b45309',
          // text-due-800 was already used by the till, the accounts screen and
          // the parent portal while this shade did not exist, so that text was
          // inheriting its colour instead of reading as a warning.
          800: '#92400e',
          900: '#78350f',
        },
        // Genuinely wrong: overdue, failed, destructive.
        danger: {
          50: '#fef2f2',
          100: '#fee2e2',
          500: '#ef4444',
          600: '#dc2626',
          700: '#b91c1c',
          900: '#7f1d1d',
        },
        info: {
          50: '#f0f9ff',
          100: '#e0f2fe',
          500: '#0ea5e9',
          600: '#0284c7',
          700: '#0369a1',
          900: '#0c4a6e',
        },
      },
      boxShadow: {
        card: '0 1px 2px 0 rgb(16 24 40 / 0.04), 0 1px 3px 0 rgb(16 24 40 / 0.08)',
        raised: '0 4px 6px -1px rgb(16 24 40 / 0.08), 0 2px 4px -2px rgb(16 24 40 / 0.05)',
        pop: '0 10px 15px -3px rgb(16 24 40 / 0.10), 0 4px 6px -4px rgb(16 24 40 / 0.06)',
      },
      borderRadius: {
        xl: '0.75rem',
        '2xl': '1rem',
      },
    },
  },
  plugins: [],
}
