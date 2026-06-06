import * as React from "react";

const TOAST_LIMIT = 3;
const TOAST_REMOVE_DELAY = 5000;

export type ToastVariant = "default" | "destructive";

export interface Toast {
  id: string;
  title?: React.ReactNode;
  description?: React.ReactNode;
  variant?: ToastVariant;
  /** Auto-dismiss duration in ms. Pass 0 to disable auto-dismiss. */
  duration?: number;
}

export type ToastOptions = Omit<Toast, "id">;

interface ToastState {
  toasts: Toast[];
}

type Action =
  | { type: "ADD_TOAST"; toast: Toast }
  | { type: "DISMISS_TOAST"; id: string };

function reducer(state: ToastState, action: Action): ToastState {
  switch (action.type) {
    case "ADD_TOAST":
      return {
        ...state,
        toasts: [action.toast, ...state.toasts].slice(0, TOAST_LIMIT),
      };
    case "DISMISS_TOAST":
      return {
        ...state,
        toasts: state.toasts.filter((t) => t.id !== action.id),
      };
    default:
      return state;
  }
}

const listeners = new Set<(state: ToastState) => void>();
let memoryState: ToastState = { toasts: [] };

function dispatch(action: Action) {
  memoryState = reducer(memoryState, action);
  listeners.forEach((listener) => listener(memoryState));
}

function genId(): string {
  return `${Date.now()}-${Math.random().toString(36).slice(2, 9)}`;
}

/** Imperatively show a toast. Returns the toast id and a dismiss helper. */
export function toast(opts: ToastOptions) {
  const id = genId();
  const duration = opts.duration ?? TOAST_REMOVE_DELAY;

  dispatch({ type: "ADD_TOAST", toast: { ...opts, id } });

  if (duration > 0) {
    setTimeout(() => {
      dispatch({ type: "DISMISS_TOAST", id });
    }, duration);
  }

  return {
    id,
    dismiss: () => dispatch({ type: "DISMISS_TOAST", id }),
  };
}

export function dismissToast(id: string) {
  dispatch({ type: "DISMISS_TOAST", id });
}

/** Subscribe to toast state. Use in the Toaster component. */
export function useToast() {
  const [state, setState] = React.useState<ToastState>(memoryState);

  React.useEffect(() => {
    listeners.add(setState);
    return () => {
      listeners.delete(setState);
    };
  }, []);

  return {
    toasts: state.toasts,
    toast,
    dismiss: dismissToast,
  };
}
