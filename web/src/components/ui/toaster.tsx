import { X } from "lucide-react";

import { cn } from "@/lib/utils";
import { useToast } from "@/components/ui/use-toast";

/**
 * Renders active toasts. Mount once near the app root (e.g. in App.tsx).
 * Trigger toasts imperatively via `toast()` from "@/components/ui/use-toast".
 */
function Toaster() {
  const { toasts, dismiss } = useToast();

  return (
    <div
      className="pointer-events-none fixed bottom-0 right-0 z-[100] flex max-h-screen w-full flex-col gap-2 p-4 sm:max-w-[420px]"
      role="region"
      aria-label="Notifications"
    >
      {toasts.map((t) => (
        <div
          key={t.id}
          role="status"
          aria-live="polite"
          className={cn(
            "pointer-events-auto relative flex w-full items-start gap-3 overflow-hidden rounded-md border p-4 pr-8 shadow-lg transition-all data-[state=open]:animate-in data-[state=open]:slide-in-from-bottom-full",
            t.variant === "destructive"
              ? "border-destructive bg-destructive text-destructive-foreground"
              : "border bg-background text-foreground",
          )}
          data-state="open"
        >
          <div className="grid flex-1 gap-1">
            {t.title ? (
              <div className="text-sm font-semibold">{t.title}</div>
            ) : null}
            {t.description ? (
              <div className="text-sm opacity-90">{t.description}</div>
            ) : null}
          </div>
          <button
            type="button"
            onClick={() => dismiss(t.id)}
            aria-label="Dismiss notification"
            className={cn(
              "absolute right-1.5 top-1.5 rounded-md p-1 opacity-60 transition-opacity hover:opacity-100 focus:outline-none focus:ring-1 focus:ring-ring",
            )}
          >
            <X className="h-4 w-4" />
          </button>
        </div>
      ))}
    </div>
  );
}

export { Toaster };
