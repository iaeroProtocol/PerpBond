import "./../styles/globals.css";
import { ReactNode } from "react";
import { Web3Providers } from "@/lib/wagmi";

export const metadata = {
  title: "Perpetual DeFi Bond",
  description: "USDC-in / USDC-yield",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body className="min-h-screen bg-neutral-950 text-neutral-100">
        <Web3Providers>
          <div className="mx-auto max-w-6xl p-6 md:p-10 space-y-8">{children}</div>
        </Web3Providers>
      </body>
    </html>
  );
}

