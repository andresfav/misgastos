export function NavIcon({ name }: { name: string }) {
  const paths: Record<string, string> = {
    "/": "m3 10 9-7 9 7v10H15v-7H9v7H3Z",
    "/movimientos": "M4 7h16m-4-4 4 4-4 4M20 17H4m4-4-4 4 4 4",
    "/anadir": "M12 5v14M5 12h14",
    "/ahorro": "M4 9h16v11H4ZM3 9l9-6 9 6M8 12v5m8-5v5",
    "/ajustes": "M4 6h16M4 12h16M4 18h16M8 3v6m8 0v6m-8 0v6",
  };
  return <svg width="22" height="22" viewBox="0 0 24 24" fill="none"
    stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"
    aria-hidden="true" focusable="false"><path d={paths[name]} /></svg>;
}
