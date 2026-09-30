import { version } from "../../package.json";

export function AppSignature({ showAppInfo = false }: { showAppInfo?: boolean }) {
  return (
    <footer className={`app-signature${showAppInfo ? "" : " auth-signature"}`}>
      {showAppInfo && <span>MisGastos</span>}
      <span>Created by <span>andresfav</span></span>
      {showAppInfo && <span>Versión {version}</span>}
    </footer>
  );
}
