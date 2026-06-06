import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { resolveApiBaseUrl } from "@/lib/pocketbase";

/**
 * M1 foundation shell. Full auth + deck/card CRUD is built on top of this
 * after review (PROJECT_PLAN.md §3, M1 feature tasks).
 */
export default function App() {
  return (
    <main className="mx-auto flex min-h-screen max-w-md flex-col items-center justify-center gap-6 p-8">
      <div className="text-center">
        <h1 className="text-2xl font-semibold tracking-tight">Pose Deck</h1>
        <p className="text-sm text-muted-foreground">
          Web foundation scaffolded. API: {resolveApiBaseUrl()}
        </p>
      </div>
      <div className="flex w-full flex-col gap-3">
        <Input type="email" placeholder="you@example.com" />
        <Button className="w-full">Sign in</Button>
      </div>
    </main>
  );
}
