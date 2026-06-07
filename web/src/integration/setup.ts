/**
 * Per-test setup for the integration suite (runs INSIDE the worker fork, unlike
 * globalSetup which runs in the main process). Installs the SSE `EventSource`
 * polyfill so the realtime contract tests can open a live `pb.*.subscribe`
 * connection in the node environment, which lacks a native `EventSource`.
 */
import { installEventSourcePolyfill } from "./eventSourcePolyfill";

installEventSourcePolyfill();
