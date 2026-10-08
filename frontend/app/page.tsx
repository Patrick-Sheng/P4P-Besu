import Link from "next/link";

export default function Home() {
  return (
    <div className="flex flex-col flex-1 min-h-screen items-center justify-center bg-background px-4">
      <div className="text-center mb-10">
        <div className="inline-flex items-center gap-2 px-3 py-1 rounded-full bg-muted text-muted-foreground text-xs font-medium mb-4">
          Hyperledger Besu · IBFT 2.0 · Chain ID 1337 · 4 Validators
        </div>
        <h1 className="text-4xl font-bold tracking-tight text-foreground">
          NZ Electronic Voting System
        </h1>
        <p className="text-muted-foreground mt-3 text-base max-w-lg mx-auto">
          A proof-of-concept blockchain-based voting system for New Zealand
          national elections. Smart contract enforces all rules — no trusted
          third party required.
        </p>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-5 w-full max-w-2xl">
        <Link
          href="/admin"
          className="group block p-7 rounded-xl border border-border hover:border-foreground/30 bg-card transition-all hover:shadow-md"
        >
          <div className="text-3xl mb-3">🏛️</div>
          <h2 className="text-lg font-semibold text-foreground">
            Electoral Commission
          </h2>
          <p className="text-muted-foreground text-sm mt-1.5 leading-relaxed">
            Register eligible voters, open and close the election, monitor live
            chain metrics and finality benchmarks.
          </p>
          <div className="mt-4 text-sm font-medium text-foreground/70 group-hover:text-foreground transition-colors">
            Admin Dashboard →
          </div>
        </Link>

        <Link
          href="/voter"
          className="group block p-7 rounded-xl border border-border hover:border-foreground/30 bg-card transition-all hover:shadow-md"
        >
          <div className="text-3xl mb-3">🗳️</div>
          <h2 className="text-lg font-semibold text-foreground">Voter</h2>
          <p className="text-muted-foreground text-sm mt-1.5 leading-relaxed">
            Cast your vote using your private key. Receive a cryptographic
            receipt tied to a block and transaction hash on-chain.
          </p>
          <div className="mt-4 text-sm font-medium text-foreground/70 group-hover:text-foreground transition-colors">
            Vote Now →
          </div>
        </Link>
      </div>

      <div className="mt-10 grid grid-cols-3 gap-4 max-w-lg w-full text-center">
        {[
          { label: "Consensus", value: "IBFT 2.0" },
          { label: "Block Time", value: "~2 seconds" },
          { label: "Finality", value: "Immediate" },
        ].map((stat) => (
          <div key={stat.label} className="p-3 rounded-lg bg-muted/50">
            <div className="text-sm font-semibold text-foreground">
              {stat.value}
            </div>
            <div className="text-xs text-muted-foreground mt-0.5">
              {stat.label}
            </div>
          </div>
        ))}
      </div>

      <p className="mt-10 text-xs text-muted-foreground text-center">
        University of Auckland · Part 4 Project · Research Prototype
      </p>
    </div>
  );
}
