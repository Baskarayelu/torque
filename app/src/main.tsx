import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import { loadConfig } from "./chain";
import { makeWagmi, WalletProviders } from "./wallet";
import "./styles.css";

loadConfig().then((cfg) => {
  createRoot(document.getElementById("root")!).render(
    <StrictMode>
      <WalletProviders wagmi={makeWagmi(cfg)}>
        <App cfg={cfg} />
      </WalletProviders>
    </StrictMode>,
  );
});
