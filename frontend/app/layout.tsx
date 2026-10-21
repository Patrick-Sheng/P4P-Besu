import type { Metadata } from "next";
import { Fira_Sans, Geist_Mono } from "next/font/google";
import "./globals.css";

// Fira Sans matches the poster typography
const firaSans = Fira_Sans({
  variable: "--font-fira-sans",
  subsets: ["latin"],
  weight: ["400", "500", "600", "700", "800"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "NZ Blockchain Voting System",
  description:
    "Proof-of-concept electronic voting system on Hyperledger Besu IBFT 2.0 — University of Auckland Part 4 Project",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      className={`${firaSans.variable} ${geistMono.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col">{children}</body>
    </html>
  );
}
