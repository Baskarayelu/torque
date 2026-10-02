import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import { loadConfig } from "./chain";
import "./styles.css";

loadConfig().then((cfg) => {
  createRoot(document.getElementById("root")!).render(
    <StrictMode>
      <App cfg={cfg} />
    </StrictMode>,
  );
});
