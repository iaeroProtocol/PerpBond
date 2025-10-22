/** @type {import('next').NextConfig} */
const nextConfig = {
  // keep your existing settings (e.g., output: 'export', images.unoptimized, etc.)
  webpack: (config) => {
    config.resolve = config.resolve || {};
    config.resolve.alias = {
      ...(config.resolve.alias || {}),
      // ⛔️ Don’t try to bundle RN storage (MetaMask SDK optional dep)
      "@react-native-async-storage/async-storage": false,
      // ⛔️ Don’t try to bundle pino-pretty (WalletConnect optional dep)
      "pino-pretty": false,
    };
    return config;
  },
};

module.exports = nextConfig;

