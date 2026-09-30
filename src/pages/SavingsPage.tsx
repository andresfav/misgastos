import { useCallback, useState, type FormEvent } from "react";
import { ErrorMessage, Loading } from "../components/Feedback";
import { MovementForm } from "../components/MovementForm";
import { useRemote } from "../hooks/useRemote";
import { useSubmit } from "../hooks/useSubmit";
import { useRequestAttempt } from "../hooks/useRequestAttempt";
import { useSetup } from "../hooks/useSetup";
import { formatDate, todayIn } from "../lib/dates";
import { friendlyError, isStaleData } from "../lib/errors";
import { formatMoney, validateMoney } from "../lib/money";
import { readReferences } from "../lib/movements";
import { refreshFinancialData } from "../lib/refresh";
import { createSavings, readSavings, readSavingsHistory, renameSavings, setSavingsActive, type SavingsAccount } from "../lib/savings";

function savingsError(error: unknown) {
  if ((error as { code?: string })?.code === "22023")
    return "Revisa el nombre, la fecha de inicio y el saldo inicial (igual o mayor que 0, con hasta dos decimales).";
  return friendlyError(error);
}

function CreateAccount({ onDone, onCancel }: { onDone: () => void; onCancel: () => void }) {
  const { settings } = useSetup();
  const [name, setName] = useState("");
  const [date, setDate] = useState(() => todayIn(settings!.timezone));
  const [balance, setBalance] = useState("0");
  const { busy, error, setError, submit } = useSubmit(savingsError);
  const attempt = useRequestAttempt("create:savings-account");
  const save = (event: FormEvent) => {
    event.preventDefault();
    let input;
    try {
      if (!name.trim()) throw new Error("Introduce el nombre de la cuenta.");
      if (!date || date > todayIn(settings!.timezone)) throw new Error("La fecha de inicio debe ser hoy o anterior.");
      if (!balance.trim()) throw new Error("Introduce el saldo inicial; puede ser 0.");
      input = { p_name: name.trim(), p_start_date: date, p_opening_balance: validateMoney(balance)! };
    } catch (failure) {
      setError((failure as Error).message);
      return;
    }
    const parameters = input;
    void submit(async () => {
      await createSavings(parameters, attempt.requestId(parameters));
      attempt.clear();
      onDone();
      refreshFinancialData();
    });
  };
  return <section className="card savings-create">
    <h2>Crear cuenta de ahorro</h2>
    <ErrorMessage message={error} />
    <form onSubmit={save}>
      <fieldset disabled={busy}>
        <label>Nombre<input autoFocus required value={name} onChange={(e) => setName(e.target.value)} /></label>
        <div className="form-row">
          <label>Fecha de inicio<input required type="date" max={todayIn(settings!.timezone)} value={date} onChange={(e) => setDate(e.target.value)} /></label>
          <label>Saldo inicial ({settings!.currency})<input required inputMode="decimal" value={balance} onChange={(e) => setBalance(e.target.value)} /><small>Igual o mayor que 0, con hasta dos decimales.</small></label>
        </div>
        <div className="form-actions">
          <button type="submit">{busy ? "Creando…" : "Crear cuenta de ahorro"}</button>
          <button type="button" className="button-secondary" onClick={onCancel}>Cancelar</button>
        </div>
      </fieldset>
    </form>
  </section>;
}

function History({ account, accounts }: { account: SavingsAccount; accounts: SavingsAccount[] }) {
  const { settings } = useSetup();
  const load = useCallback(() => readSavingsHistory(account.id), [account.id]);
  const { data, loading, error, reload } = useRemote(load);
  const name = (id: string | null) => id === null ? "Disponible" : accounts.find((a) => a.id === id)?.name || "Cuenta de ahorro";
  return <section className="savings-detail" aria-label={`Historial de ${account.name}`}>
    <h3>Historial</h3>
    <ErrorMessage message={error} />
    {error && <button onClick={reload}>Reintentar historial</button>}
    {loading ? <Loading text="Cargando historial…" /> : !error && data && (
      data.length ? <ul className="movement-list">{data.map((row) => <li key={`${row.kind}:${row.id}`} className="savings-history-row">
        <div className="movement-heading">
          <div><span className={`movement-type ${row.kind}`}>{row.kind === "income" ? "Ingreso directo" : row.kind === "transfer" && row.to_savings_account_id === account.id ? "Transferencia recibida" : "Transferencia enviada"}</span><time dateTime={row.date}>{formatDate(row.date)}</time></div>
          <strong>{formatMoney(row.amount, settings!.currency)}</strong>
        </div>
        <div className="movement-details">
          {row.description && <span>{row.description}</span>}
          {row.kind === "transfer" && <span>{name(row.from_savings_account_id)} → {name(row.to_savings_account_id)}</span>}
          {row.kind === "income" && <span>Destino: {account.name}</span>}
        </div>
      </li>)}</ul> : <p className="empty">Esta cuenta todavía no tiene movimientos.</p>
    )}
  </section>;
}

type QuickAction = "add" | "withdraw" | "move";
function QuickTransfer({ account, action, onClose, onSaved }: { account: SavingsAccount; action: QuickAction; onClose: () => void; onSaved: () => void }) {
  const { data, loading, error, reload } = useRemote(readReferences);
  const other = data?.accounts.find((a) => a.is_active && a.id !== account.id);
  const active = data?.accounts.some((a) => a.id === account.id && a.is_active);
  return <section className="savings-detail">
    <h3>{action === "add" ? "Añadir dinero" : action === "withdraw" ? "Retirar dinero" : "Mover a otra cuenta"}</h3>
    <ErrorMessage message={error} />
    {error && <button onClick={reload}>Reintentar carga</button>}
    {loading ? <Loading /> : !error && data && (active && (action !== "move" || other) ?
      <MovementForm kind="transfer" refs={data} initialTransfer={{ from: action === "add" ? "" : account.id, to: action === "add" ? account.id : action === "move" ? other!.id : "" }} onSaved={onSaved} onConflict={reload} onCancel={onClose} />
      : <p className="notice">{!active ? "Esta cuenta ya no está activa." : "Necesitas otra cuenta de ahorro activa para mover dinero."}</p>)}
    {(loading || error || !active || (action === "move" && !other)) && <button className="button-secondary" onClick={onClose}>Cerrar</button>}
  </section>;
}

function AccountCard({ account, accounts, onMessage }: { account: SavingsAccount; accounts: SavingsAccount[]; onMessage: (message: string) => void }) {
  const { settings } = useSetup();
  const [editing, setEditing] = useState(false);
  const [name, setName] = useState(account.name);
  const [history, setHistory] = useState(false);
  const [action, setAction] = useState<QuickAction | null>(null);
  const { busy, error, setError, submit } = useSubmit(savingsError);
  const mutate = (rename: boolean) => {
    if (rename && !name.trim()) { setError("Introduce un nombre."); return; }
    void submit(async () => {
      try {
        if (rename) await renameSavings(account, name.trim());
        else await setSavingsActive(account);
      } catch (failure) {
        if (isStaleData(failure)) {
          onMessage("La cuenta ha cambiado. Recargando los datos; revisa la versión actual antes de volver a guardar.");
          refreshFinancialData();
        }
        throw failure;
      }
      onMessage(rename ? "Nombre actualizado." : account.is_active ? "Cuenta desactivada. Conserva su saldo e historial." : "Cuenta restaurada.");
      refreshFinancialData();
    });
  };
  return <article className="card savings-account">
    <div className="catalog-name"><h2>{account.name}</h2><span className="badge">{account.is_active ? "Activa" : "Inactiva"}</span></div>
    <dl className="savings-facts">
      <div><dt>Saldo actual</dt><dd className="savings-balance">{formatMoney(account.current_balance, settings!.currency)}</dd></div>
      <div><dt>Saldo inicial</dt><dd>{formatMoney(account.opening_balance, settings!.currency)}</dd></div>
      <div><dt>Fecha de inicio</dt><dd>{formatDate(account.start_date)}</dd></div>
    </dl>
    {!account.is_active && <p className="notice">Conserva su saldo e historial. Restáurala para registrar nuevos movimientos.</p>}
    <ErrorMessage message={error} />
    {editing ? <form onSubmit={(e) => { e.preventDefault(); mutate(true); }}><fieldset disabled={busy}>
      <label>Nuevo nombre<input autoFocus required value={name} onChange={(e) => setName(e.target.value)} /></label>
      <div className="form-actions"><button type="submit">{busy ? "Guardando…" : "Guardar nombre"}</button><button type="button" className="button-secondary" onClick={() => setEditing(false)}>Cancelar</button></div>
    </fieldset></form> : <div className="form-actions">
      <button className="button-secondary" disabled={busy || action !== null} onClick={() => setEditing(true)}>Renombrar</button>
      <button className="button-secondary" disabled={busy || action !== null} onClick={() => mutate(false)}>{busy ? "Guardando…" : account.is_active ? "Desactivar" : "Restaurar"}</button>
      <button className="button-secondary" disabled={busy} aria-expanded={history} onClick={() => setHistory(!history)}>{history ? "Ocultar historial" : "Ver detalle / historial"}</button>
    </div>}
    {account.is_active && !editing && action === null && <div className="form-actions">
      <button disabled={busy} onClick={() => setAction("add")}>Añadir dinero</button>
      <button disabled={busy} onClick={() => setAction("withdraw")}>Retirar</button>
      <button disabled={busy || !accounts.some((a) => a.is_active && a.id !== account.id)} onClick={() => setAction("move")}>Mover</button>
    </div>}
    {action && <QuickTransfer account={account} action={action} onClose={() => setAction(null)} onSaved={() => { setAction(null); onMessage("Transferencia guardada correctamente."); }} />}
    {history && <History account={account} accounts={accounts} />}
  </article>;
}

export function SavingsPage() {
  const { data, loading, error, reload } = useRemote(readSavings);
  const [creating, setCreating] = useState(false);
  const [message, setMessage] = useState("");
  return <>
    <div className="page-heading"><div><p className="eyebrow">TUS CUENTAS</p><h1>Ahorro</h1><p>Todos tus ahorros, incluidas las cuentas inactivas.</p></div><button className="button-secondary" disabled={loading} onClick={reload}>Actualizar</button></div>
    {message && <p className="notice" role="status">{message}</p>}
    {!creating && <button className="savings-create-button" onClick={() => setCreating(true)}>Crear cuenta de ahorro</button>}
    {creating && <CreateAccount onCancel={() => setCreating(false)} onDone={() => { setCreating(false); setMessage("Cuenta de ahorro creada correctamente."); }} />}
    <ErrorMessage message={error} />
    {error && <button onClick={reload}>Reintentar carga</button>}
    {loading ? <Loading text="Cargando cuentas de ahorro…" /> : !error && data && (data.length ?
      <div className="savings-grid">{data.map((account) => <AccountCard key={`${account.id}:${account.version}`} account={account} accounts={data} onMessage={setMessage} />)}</div>
      : <section className="card empty"><h2>Empieza a organizar tus ahorros</h2><p>Crea tu primera cuenta con el dinero que ya tienes ahorrado. Después podrás añadir, retirar o mover dinero.</p>{!creating && <button onClick={() => setCreating(true)}>Crear cuenta de ahorro</button>}</section>)}
  </>;
}
