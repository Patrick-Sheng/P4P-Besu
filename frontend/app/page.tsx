import Link from "next/link";
import { Landmark, Vote } from "lucide-react";

import { PosterFooter, PosterHeader, PosterSection, SubHeading, VoteJourney } from "@/components/poster";

export default function Home() {
  return (
    <div className="flex flex-col min-h-screen bg-background">
      <PosterHeader
        title="#68 Assessing the Suitability of Blockchain Frameworks for New Zealand General Elections"
        left="Patrick Sheng & Eason Chang"
        right="Hyperledger Besu · IBFT 2.0 · Chain ID 1337 · 4 Validators"
      />

      <main className="w-full max-w-[1500px] mx-auto px-6 py-6 space-y-6">
        <PosterSection title="NZ Electronic Voting System">
          <p className="text-navy text-base lg:text-lg max-w-3xl mb-5">
            A proof-of-concept <strong>private blockchain</strong> voting system for New Zealand
            general elections. The smart contract enforces every rule, so{" "}
            <strong>no single organisation</strong> can change the result.
          </p>

          <div className="grid grid-cols-1 md:grid-cols-2 gap-5">
            <PortalCard
              href="/admin"
              icon={<Landmark className="size-9 text-navy" strokeWidth={1.8} />}
              title="Electoral Commission"
              text="Register eligible voters, open and close the election, monitor live chain metrics and finality benchmarks."
              cta="Admin Dashboard →"
              tint="#cfe6f7"
            />
            <PortalCard
              href="/voter"
              icon={<Vote className="size-9 text-navy" strokeWidth={1.8} />}
              title="Voter"
              text="Cast your vote using your private key. Receive a receipt tied to a block and transaction hash on-chain."
              cta="Vote Now →"
              tint="#dcefc4"
            />
          </div>

          <div className="mt-5 grid grid-cols-3 gap-4 max-w-2xl">
            {[
              { label: "Consensus", value: "IBFT 2.0" },
              { label: "Block time", value: "~2 seconds" },
              { label: "Finality", value: "Immediate" },
            ].map((stat) => (
              <div key={stat.label} className="border-[1.5px] border-navy/80 rounded-xl bg-card py-3 text-center">
                <div className="text-xl font-extrabold text-navy">{stat.value}</div>
                <div className="text-xs font-semibold text-muted-foreground mt-0.5">{stat.label}</div>
              </div>
            ))}
          </div>
        </PosterSection>

        <PosterSection title="How Your Vote Is Recorded">
          <VoteJourney />
        </PosterSection>
      </main>

      <PosterFooter />
    </div>
  );
}

function PortalCard({
  href,
  icon,
  title,
  text,
  cta,
  tint,
}: {
  href: string;
  icon: React.ReactNode;
  title: string;
  text: string;
  cta: string;
  tint: string;
}) {
  return (
    <Link
      href={href}
      className="group flex gap-4 p-5 rounded-xl border-[1.5px] border-navy/80 bg-card transition-all hover:shadow-md hover:-translate-y-0.5"
    >
      <div className="h-16 w-16 shrink-0 rounded-xl flex items-center justify-center" style={{ background: tint }}>
        {icon}
      </div>
      <div>
        <SubHeading>{title}</SubHeading>
        <p className="text-sm text-foreground/80 mt-2 leading-relaxed">{text}</p>
        <div className="mt-3 text-sm font-bold text-orange group-hover:underline">{cta}</div>
      </div>
    </Link>
  );
}
