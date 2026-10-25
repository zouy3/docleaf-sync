import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "DocLeaf · 离线文档阅读器",
  description: "像打开文档一样阅读，本地、离线、私密。",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="zh-CN"><body>{children}</body></html>;
}
