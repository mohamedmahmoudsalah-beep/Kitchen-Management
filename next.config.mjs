/** @type {import('next').NextConfig} */
const securityHeaders = [
  // منع فتح الموقع جوه iframe في موقع تاني (Clickjacking)
  { key: 'X-Frame-Options', value: 'DENY' },
  { key: 'Content-Security-Policy', value: "frame-ancestors 'none'; base-uri 'self'; form-action 'self'; object-src 'none'" },
  { key: 'X-Content-Type-Options', value: 'nosniff' },
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
  { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=(), payment=(), usb=()' },
  { key: 'Strict-Transport-Security', value: 'max-age=63072000' },
];

const nextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,
  // الرجوع لصفحة اتزارت من 30 ثانية بيظهر فورًا من غير ما السيرفر يتسأل تاني (الداتا نفسها بتتحمّل في المتصفح بـ Cache قصير)
  experimental: { staleTimes: { dynamic: 30 } },
  async headers() {
    return [{ source: '/:path*', headers: securityHeaders }];
  },
};

export default nextConfig;
