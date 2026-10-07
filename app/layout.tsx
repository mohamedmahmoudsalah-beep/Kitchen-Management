import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'Kitchen Management System',
  description: 'Breadfast kitchens inventory',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
