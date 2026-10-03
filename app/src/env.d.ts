/// <reference types="vite/client" />
interface ImportMetaEnv {
  /** Optional private RPC for the dashboard's own reads (set in the hosting provider's env, never in the repo). */
  readonly VITE_RH_RPC_URL?: string;
}
