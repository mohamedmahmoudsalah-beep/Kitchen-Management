/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // الرجوع لصفحة اتزارت من 30 ثانية بيظهر فورًا من غير ما السيرفر يتسأل تاني (الداتا نفسها بتتحمّل في المتصفح بـ Cache قصير)
  experimental: { staleTimes: { dynamic: 30 } },
};

export default nextConfig;
