import type { Metadata, Viewport } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Hop Console",
  description: "Sign in to the Hop console: keys, usage, billing, and your team.",
  icons: { icon: "/hop-mark.svg" },
};

export const viewport: Viewport = {
  themeColor: [
    { media: "(prefers-color-scheme: dark)", color: "#07090b" },
    { media: "(prefers-color-scheme: light)", color: "#f6f8f7" },
  ],
};

// Set data-theme before paint from a saved choice, falling back to the OS preference, so there is no
// flash of the wrong theme. Mirrors the marketing site.
const themeScript = `(function(){try{var t=localStorage.getItem('hop-theme');if(!t){t=matchMedia('(prefers-color-scheme: light)').matches?'light':'dark';}document.documentElement.setAttribute('data-theme',t);}catch(e){}})();`;

// Poppins, the marketing site's display face, so the console reads as the same product.
const fonts =
  "https://fonts.googleapis.com/css2?family=Poppins:wght@400;500;600;650&display=swap";

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: themeScript }} />
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
        <link rel="stylesheet" href={fonts} />
        {/* Jason's Font Awesome Pro kit, for real icons (never emoji). */}
        <script src="https://kit.fontawesome.com/bcb2ad36f1.js" crossOrigin="anonymous" async />
      </head>
      <body>{children}</body>
    </html>
  );
}
