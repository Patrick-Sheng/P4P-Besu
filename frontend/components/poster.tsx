// Building blocks that reproduce the P4P poster's visual language: the orange
// title band, navy tab-style section headers over outlined panels, navy
// sub-headings with an orange underline, and the 0-6 "vote journey" strip.
import type { ReactNode } from "react";
import {
  Vote,
  Smartphone,
  Share2,
  Layers,
  CircleCheck,
  ClipboardCheck,
  Database,
  type LucideIcon,
} from "lucide-react";

import { cn } from "@/lib/utils";

export const PARTY_COLORS = ["#2f80ed", "#f26b1d", "#22a06b", "#f2b705", "#8e44ad"];

export function PosterHeader({
  title,
  left,
  right,
  children,
  compact,
}: {
  title: ReactNode;
  left?: ReactNode;
  right?: ReactNode;
  children?: ReactNode;
  compact?: boolean;
}) {
  return (
    <header className="bg-orange text-white border-b-4 border-[#f59a3e]">
      <div className={cn("mx-auto px-4", compact ? "max-w-md py-3" : "max-w-[1500px] px-6 py-4")}>
        <div className="flex items-start justify-between gap-4">
          <h1
            className={cn(
              "font-extrabold leading-tight tracking-tight",
              compact ? "text-lg" : "text-3xl lg:text-4xl"
            )}
          >
            {title}
          </h1>
          {children}
        </div>
        {(left || right) && (
          <div
            className={cn(
              "flex flex-wrap items-center justify-between gap-x-6 gap-y-1 font-semibold",
              compact ? "mt-1 text-xs" : "mt-2 text-base lg:text-lg"
            )}
          >
            <span>{left}</span>
            <span>{right}</span>
          </div>
        )}
      </div>
    </header>
  );
}

/** Navy tab heading sitting on top of a navy-outlined panel. */
export function PosterSection({
  title,
  children,
  className,
  action,
  size = "md",
}: {
  title: ReactNode;
  children: ReactNode;
  className?: string;
  action?: ReactNode;
  size?: "sm" | "md";
}) {
  return (
    <section className={cn("flex flex-col", className)}>
      <div className="flex items-end justify-between gap-3">
        <h2
          className={cn(
            "bg-navy text-white font-extrabold rounded-t-xl",
            size === "sm" ? "px-4 py-1.5 text-base" : "px-5 py-2 text-xl lg:text-2xl"
          )}
        >
          {title}
        </h2>
        {action && <div className="pb-1.5">{action}</div>}
      </div>
      <div
        className={cn(
          "flex-1 border-2 border-navy rounded-xl rounded-tl-none bg-peach",
          size === "sm" ? "p-3" : "p-4"
        )}
      >
        {children}
      </div>
    </section>
  );
}

/** Inner card: thin navy outline with an orange-underlined navy heading. */
export function PosterCard({
  title,
  children,
  className,
}: {
  title?: ReactNode;
  children: ReactNode;
  className?: string;
}) {
  return (
    <div className={cn("border-[1.5px] border-navy/80 rounded-xl bg-card px-4 py-3", className)}>
      {title && <SubHeading className="mb-2">{title}</SubHeading>}
      {children}
    </div>
  );
}

export function SubHeading({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <h3 className={cn("inline-block text-navy font-bold text-lg leading-tight", className)}>
      {children}
      <span className="block h-[3px] mt-1 rounded-full bg-orange" />
    </h3>
  );
}

// ─── Vote journey (poster steps 0-6) ─────────────────────────────────────────

interface JourneyStep {
  title: string;
  text: string;
  icon: LucideIcon;
  badge: string;
  bg: string;
}

export const JOURNEY: JourneyStep[] = [
  { title: "Vote cast", text: "You pick a candidate and submit your ballot.", icon: Vote, badge: "#f26b1d", bg: "#fad7b5" },
  { title: "Vote sent", text: "Your ballot is signed with your digital key and sent to the network.", icon: Smartphone, badge: "#f7931e", bg: "#fbddba" },
  { title: "Shared", text: "Copies of the ballot are passed to every trusted computer.", icon: Share2, badge: "#f9a825", bg: "#fce3b0" },
  { title: "Checked", text: "The voting rules confirm you are enrolled, haven't voted yet, and the poll is open.", icon: ClipboardCheck, badge: "#fbc02d", bg: "#fdf0b5" },
  { title: "Proposed", text: "One computer groups waiting ballots into a block.", icon: Layers, badge: "#7cb342", bg: "#dcefc4" },
  { title: "Consensus", text: "The computers check the block and approve it once most of them agree.", icon: CircleCheck, badge: "#43a047", bg: "#cdebcb" },
  { title: "Recorded", text: "Your vote is added to the tally and stored permanently on every computer.", icon: Database, badge: "#1e88e5", bg: "#cfe6f7" },
];

/**
 * The poster's 7-step strip. `active` highlights steps up to and including that
 * index (-1 = none, all steps shown at full colour when `active` is undefined).
 * `layout="row"` for the projector, `"list"` for the phone.
 */
export function VoteJourney({
  active,
  layout = "row",
  showText = true,
}: {
  active?: number;
  layout?: "row" | "list";
  showText?: boolean;
}) {
  const state = (i: number) =>
    active === undefined ? "on" : i < active ? "done" : i === active ? "current" : "off";

  if (layout === "list") {
    return (
      <ol className="space-y-1.5">
        {JOURNEY.map((s, i) => {
          const st = state(i);
          const Icon = s.icon;
          return (
            <li
              key={s.title}
              className={cn(
                "flex items-center gap-3 rounded-lg px-3 py-2 transition-all duration-300",
                st === "off" && "opacity-40 grayscale",
                st === "current" && "ring-2 ring-navy/70 scale-[1.02]"
              )}
              style={{ background: s.bg }}
            >
              <span
                className="h-6 w-6 shrink-0 rounded-full text-white text-xs font-bold flex items-center justify-center"
                style={{ background: s.badge }}
              >
                {st === "done" || (st === "current" && i === JOURNEY.length - 1) ? "✓" : i}
              </span>
              <Icon className="size-5 shrink-0 text-navy" strokeWidth={2.2} />
              <div className="min-w-0">
                <div className="text-sm font-bold text-navy leading-tight">{s.title}</div>
                {showText && st === "current" && (
                  <div className="text-xs text-navy/80 leading-snug">{s.text}</div>
                )}
              </div>
              {/* the last step is an end state, not work in progress */}
              {st === "current" && i < JOURNEY.length - 1 && (
                <span className="ml-auto h-2.5 w-2.5 shrink-0 rounded-full bg-navy animate-ping" />
              )}
            </li>
          );
        })}
      </ol>
    );
  }

  return (
    <ol className="grid grid-cols-7 gap-2">
      {JOURNEY.map((s, i) => {
        const st = state(i);
        const Icon = s.icon;
        return (
          <li
            key={s.title}
            className={cn(
              "relative rounded-xl px-2 pt-2.5 pb-2.5 text-center flex flex-col items-center transition-all duration-300",
              st === "off" && "opacity-45 grayscale",
              st === "current" && "ring-[3px] ring-navy -translate-y-1 shadow-lg"
            )}
            style={{ background: s.bg }}
          >
            <span
              className="h-8 w-8 rounded-full text-white font-extrabold flex items-center justify-center"
              style={{ background: s.badge }}
            >
              {i}
            </span>
            <div className="mt-1 font-extrabold text-navy text-base leading-tight">{s.title}</div>
            <Icon className="my-1.5 size-9 text-navy" strokeWidth={1.8} />
            {showText && <p className="text-[11px] leading-snug text-navy/85">{s.text}</p>}
            {i < JOURNEY.length - 1 && (
              <span
                className="absolute -right-[9px] top-1/2 z-10 -translate-y-1/2 text-lg font-black"
                style={{ color: JOURNEY[i + 1].badge }}
              >
                ▶
              </span>
            )}
          </li>
        );
      })}
    </ol>
  );
}

export function PosterFooter({ compact }: { compact?: boolean }) {
  return (
    <footer className="mt-auto bg-orange text-white">
      <div
        className={cn(
          "mx-auto px-4 py-3 flex flex-wrap items-center justify-between gap-2 font-semibold",
          compact ? "max-w-md text-[11px]" : "max-w-[1500px] px-6 text-sm"
        )}
      >
        <span>Hyperledger Besu · IBFT 2.0 private blockchain</span>
        <span>Department of Electrical, Computer, and Software Engineering · Part IV Research Project 2026</span>
      </div>
    </footer>
  );
}
