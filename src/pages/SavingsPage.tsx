import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { moneyUnits, sumAmounts } from "../lib/home";
import { ErrorMessage, Loading } from "../components/Feedback";
import { useRemote } from "../hooks/useRemote";
import { useSubmit } from "../hooks/useSubmit";
import { useRequestAttempt } from "../hooks/useRequestAttempt";
import { useSetup } from "../hooks/useSetup";
import { formatDate, todayIn } from "../lib/dates";
import { friendlyError, isStaleData } from "../lib/errors";
import { formatMoney, validateMoney } from "../lib/money";
import { refreshFinancialData } from "../lib/refresh";
import { correctSavingsOpeningBalance, createSavings, deleteSavings, readSavings, readSavingsHistory, renameSavings, setSavingsActive, type SavingsAccount } from "../lib/savings";

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
          <label>Saldo inicial ({settings!.currency})<input required inputMode="decimal" value={balance} onChange={(e) => setBalance(e.target.value)} /><small>Dinero que ya existe en esta cuenta al empezar a usar MisGastos. No se registra como ingreso.<br />Igual o mayor que 0, con hasta dos decimales.</small></label>
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
    <h2>Movimientos</h2>
    <ErrorMessage message={error} />
    {error && <button onClick={reload}>Reintentar historial</button>}
    {loading ? <Loading text="Cargando historial…" /> : !error && data && (
      data.length ? <ul className="movement-list">{data.map((row) => <li key={`${row.kind}:${row.id}`} className="savings-history-row">
        <div className="movement-heading">
          <div><span className={`movement-type ${row.kind}`}>{row.kind === "income" ? "Ingreso directo" : row.kind === "transfer" && row.to_savings_account_id === account.id ? "Transferencia recibida" : "Transferencia enviada"}</span><time dateTime={row.date}>{formatDate(row.date)}</time></div>
          <strong>{row.kind === "transfer" && row.from_savings_account_id === account.id ? "−" : "+"}{formatMoney(row.amount, settings!.currency)}</strong>
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

function AddMoneyChoice({ onChoose, onClose }: {
  onChoose: (choice: "available" | "income") => void;
  onClose: () => void;
}) {
  const dialog = useRef<HTMLDialogElement>(null);
  const unmounting = useRef(false);
  useEffect(() => {
    const node = dialog.current!;
    node.showModal();
    return () => {
      unmounting.current = true;
      node.close();
    };
  }, []);
  return <dialog ref={dialog} className="savings-add-dialog card" aria-labelledby="savings-add-title" onClose={() => { if (!unmounting.current) onClose(); }}>
    <div className="detail-heading">
      <h2 id="savings-add-title">Añadir dinero</h2>
      <button type="button" className="button-quiet" onClick={() => dialog.current?.close()}>Cerrar</button>
    </div>
    <div className="savings-add-options">
      <button type="button" className="savings-add-option" onClick={() => onChoose("available")}>
        <strong>Desde Disponible</strong>
        <span>Mueve dinero que ya tienes disponible a esta cuenta.</span>
      </button>
      <button type="button" className="savings-add-option" onClick={() => onChoose("income")}>
        <strong>Nuevo ingreso</strong>
        <span>Registra dinero nuevo recibido directamente en esta cuenta de ahorro.</span>
      </button>
    </div>
    <div className="form-actions">
      <button type="button" className="button-secondary" onClick={() => dialog.current?.close()}>Cancelar</button>
    </div>
  </dialog>;
}

function AccountDetail({ account, accounts, onMessage, onDeleted }: { account: SavingsAccount; accounts: SavingsAccount[]; onMessage: (message: string) => void; onDeleted: (message: string) => void }) {
  const { settings } = useSetup();
  const navigate = useNavigate();
  const [editing, setEditing] = useState(false);
  const [correcting, setCorrecting] = useState(false);
  const [confirmingDelete, setConfirmingDelete] = useState(false);
  const [blockedBalance, setBlockedBalance] = useState<SavingsAccount["current_balance"] | null>(null);
  const [name, setName] = useState(account.name);
  const [openingBalance, setOpeningBalance] = useState(String(account.opening_balance));
  const [choosingAdd, setChoosingAdd] = useState(false);
  const { busy, error, setError, submit } = useSubmit(savingsError);
  const correctAttempt = useRequestAttempt(`correct:savings-account:${account.id}`);
  const deleteAttempt = useRequestAttempt(`delete:savings-account:${account.id}`);
  const saveName = () => {
    if (!name.trim()) { setError("Introduce un nombre."); return; }
    void submit(async () => {
      try {
        await renameSavings(account, name.trim());
      } catch (failure) {
        if (isStaleData(failure)) {
          onMessage("La cuenta ha cambiado. Recargando los datos; revisa la versión actual antes de volver a guardar.");
          refreshFinancialData();
        }
        throw failure;
      }
      setEditing(false);
      onMessage("Nombre actualizado.");
      refreshFinancialData();
    });
  };
  const reactivate = () => void submit(async () => {
    try {
      await setSavingsActive(account);
    } catch (failure) {
      if (isStaleData(failure)) refreshFinancialData();
      throw failure;
    }
    onMessage("Cuenta reactivada. Ya puedes mover el saldo pendiente.");
    refreshFinancialData();
  });
  const correctOpening = (event: FormEvent) => {
    event.preventDefault();
    let value: string;
    try { value = validateMoney(openingBalance)!; }
    catch (failure) { setError((failure as Error).message); return; }
    const parameters = { p_id: account.id, p_opening_balance: value, p_expected_version: account.version };
    void submit(async () => {
      try {
        await correctSavingsOpeningBalance(account, value, correctAttempt.requestId(parameters));
      } catch (failure) {
        if (isStaleData(failure)) correctAttempt.clear();
        throw failure;
      }
      correctAttempt.clear();
      setCorrecting(false);
      onMessage("Saldo inicial corregido.");
      refreshFinancialData();
    });
  };
  const remove = () => {
    const parameters = { p_id: account.id, p_expected_version: account.version };
    void submit(async () => {
      try {
        const result = await deleteSavings(account, deleteAttempt.requestId(parameters));
        deleteAttempt.clear();
        if (result.mode === "blocked") {
          setBlockedBalance(result.balance);
          setConfirmingDelete(false);
          return;
        }
        onDeleted(result.mode === "hard_deleted"
          ? "Cuenta eliminada definitivamente junto con su saldo inicial."
          : "Cuenta borrada. Sus movimientos anteriores se conservan.");
        refreshFinancialData();
      } catch (failure) {
        if (isStaleData(failure)) {
          deleteAttempt.clear();
          refreshFinancialData();
        }
        throw failure;
      }
    });
  };
  const deleteLabel = account.can_hard_delete ? "Eliminar cuenta" : "Borrar cuenta";
  const openAddFlow = (choice: "available" | "income") => {
    const params = new URLSearchParams({ tipo: choice === "available" ? "transfer" : "income" });
    if (choice === "available") params.set("destino", account.id);
    else params.set("cuenta", account.id);
    navigate(`/anadir?${params.toString()}`);
  };
  const openTransferFlow = (destination?: string) => {
    const params = new URLSearchParams({ tipo: "transfer", origen: account.id });
    if (destination) params.set("destino", destination);
    navigate(`/anadir?${params.toString()}`);
  };
  const otherActiveAccount = accounts.find((item) => item.is_active && item.id !== account.id);
  return <article className="savings-account">
    <header className="savings-account-heading">
      <h1>{account.name}</h1>
      <p className="savings-balance">{formatMoney(account.current_balance, settings!.currency)}</p>
    </header>
    {account.is_active && <div className="savings-quick-actions">
      <button disabled={busy || editing || choosingAdd} onClick={() => setChoosingAdd(true)}>Añadir dinero</button>
      <button className="button-secondary" disabled={busy || editing || choosingAdd} onClick={() => openTransferFlow()}>Retirar a Disponible</button>
      <button className="button-secondary" disabled={busy || editing || choosingAdd || !otherActiveAccount} onClick={() => openTransferFlow(otherActiveAccount?.id)}>Mover a otra cuenta</button>
    </div>}
    {choosingAdd && <AddMoneyChoice onClose={() => setChoosingAdd(false)} onChoose={openAddFlow} />}
    {!account.is_active && <p className="notice"><strong>Cuenta por revisar.</strong><br />Conserva saldo pendiente o procede de la experiencia anterior. Reactívala si necesitas mover dinero.</p>}
    <section className="savings-detail">
      <h2>Información</h2>
      <dl className="savings-facts">
        <div><dt>Saldo actual</dt><dd>{formatMoney(account.current_balance, settings!.currency)}</dd></div>
        <div><dt>Saldo inicial</dt><dd>{formatMoney(account.opening_balance, settings!.currency)}</dd></div>
        <div><dt>Fecha de inicio</dt><dd>{new Intl.DateTimeFormat("es-ES", { dateStyle: "long", timeZone: "UTC" }).format(new Date(`${account.start_date}T12:00:00Z`))}</dd></div>
        <div><dt>Estado</dt><dd>{account.is_active ? "Activa" : "Por revisar"}</dd></div>
      </dl>
    </section>
    <History account={account} accounts={accounts} />
    <section className="savings-detail">
      <h2>Gestionar cuenta</h2>
      <ErrorMessage message={error} />
      {editing ? <form onSubmit={(e) => { e.preventDefault(); saveName(); }}><fieldset disabled={busy}>
        <label>Nuevo nombre<input autoFocus required value={name} onChange={(e) => setName(e.target.value)} /></label>
        <div className="form-actions"><button type="submit">{busy ? "Guardando…" : "Guardar nombre"}</button><button type="button" className="button-secondary" onClick={() => setEditing(false)}>Cancelar</button></div>
      </fieldset></form> : correcting ? <form onSubmit={correctOpening}><fieldset disabled={busy}>
        <label>Saldo inicial ({settings!.currency})<input autoFocus required inputMode="decimal" value={openingBalance} onChange={(e) => setOpeningBalance(e.target.value)} /><small>Solo puede corregirse antes de que la cuenta tenga movimientos o alcance un período cerrado.</small></label>
        <div className="form-actions"><button type="submit">{busy ? "Guardando…" : "Guardar saldo inicial"}</button><button type="button" className="button-secondary" onClick={() => setCorrecting(false)}>Cancelar</button></div>
      </fieldset></form> : <div className="form-actions">
        <button className="button-secondary" disabled={busy || choosingAdd} onClick={() => setEditing(true)}>Renombrar</button>
        {account.can_correct_opening_balance && <button className="button-secondary" disabled={busy || choosingAdd} onClick={() => setCorrecting(true)}>Corregir saldo inicial</button>}
        {!account.is_active && <button className="button-secondary" disabled={busy || choosingAdd} onClick={reactivate}>{busy ? "Guardando…" : "Reactivar cuenta"}</button>}
      </div>}
      <hr />
      {blockedBalance !== null ? <div className="delete-confirm">
        <p><strong>No puedes borrar esta cuenta todavía.</strong></p>
        <p>Quedan {formatMoney(blockedBalance, settings!.currency)}. Mueve primero el saldo a Disponible o a otra cuenta de ahorro.</p>
        <div className="form-actions">
          {account.is_active ? <button onClick={() => { setBlockedBalance(null); openTransferFlow(); }}>Mover saldo</button>
            : <button onClick={reactivate} disabled={busy}>Reactivar cuenta</button>}
          <button className="button-secondary" onClick={() => setBlockedBalance(null)} disabled={busy}>Cerrar</button>
        </div>
      </div> : confirmingDelete ? <div className="delete-confirm">
        <p><strong>{deleteLabel}</strong></p>
        <p>{account.can_hard_delete
          ? "Esta cuenta no tiene movimientos asociados. Se eliminará definitivamente junto con su saldo inicial. Esta acción no se puede deshacer."
          : "La cuenta dejará de aparecer en Ahorro. Sus movimientos anteriores se conservarán en el historial."}</p>
        <div className="form-actions">
          <button className="button-danger" disabled={busy} onClick={remove}>{busy ? "Guardando…" : account.can_hard_delete ? "Eliminar" : "Borrar"}</button>
          <button className="button-secondary" disabled={busy} onClick={() => setConfirmingDelete(false)}>Cancelar</button>
        </div>
      </div> : <button className="button-quiet danger-text" disabled={busy || choosingAdd || editing || correcting} onClick={() => setConfirmingDelete(true)}>{deleteLabel}</button>}
    </section>
  </article>;
}

function AccountList({ accounts, currency }: { accounts: SavingsAccount[]; currency: Parameters<typeof formatMoney>[1] }) {
  return <ul className="savings-list">{accounts.map((account) => <li key={account.id}>
    <Link className={`savings-account-link${account.is_active ? "" : " is-inactive"}`} to={`?cuenta=${encodeURIComponent(account.id)}`}>
      <span className="savings-account-name">{account.name}</span>
      <small>{account.is_active ? "Activa" : "Saldo pendiente"}</small>
      <strong>{formatMoney(account.current_balance, currency)}</strong>
      <span className="savings-chevron" aria-hidden="true">›</span>
    </Link>
  </li>)}</ul>;
}

export function SavingsPage() {
  const { settings } = useSetup();
  const navigate = useNavigate();
  const { data, loading, error, reload } = useRemote(readSavings);
  const [params] = useSearchParams();
  const selectedId = params.get("cuenta");
  const [creating, setCreating] = useState(false);
  const [message, setMessage] = useState("");
  const page = useRef<HTMLDivElement>(null);
  useEffect(() => {
    window.scrollTo(0, 0);
    page.current?.focus({ preventScroll: true });
  }, [selectedId]);
  const selected = data?.find((account) => account.id === selectedId);
  const active = data?.filter((account) => account.is_active) ?? [];
  const pending = data?.filter((account) => !account.is_active && moneyUnits(account.current_balance) !== 0n) ?? [];
  return <div className="savings-page" ref={page} tabIndex={-1}>
    {selectedId ? <Link className="text-link savings-back" to="/ahorro">← Ahorro</Link> : <h1>Ahorro</h1>}
    {message && <p className="notice" role="status">{message}</p>}
    <ErrorMessage message={error} />
    {error && <button onClick={reload}>Reintentar carga</button>}
    {loading ? <Loading text="Cargando cuentas de ahorro…" /> : !error && data && (selectedId ? (
      selected ? <AccountDetail key={`${selected.id}:${selected.version}`} account={selected} accounts={data} onMessage={setMessage} onDeleted={(nextMessage) => { setMessage(nextMessage); navigate("/ahorro", { replace: true }); }} />
        : <p className="empty">Esta cuenta no está disponible.</p>
    ) : <>
      <dl className="savings-total"><div><dt>Total ahorrado</dt><dd>{formatMoney(sumAmounts(data.map((account) => account.current_balance)), settings!.currency)}</dd></div></dl>
      {!active.length && !pending.length && !creating && <p>Aún no tienes cuentas de ahorro activas.</p>}
      {!creating && <button className="savings-create-button" onClick={() => setCreating(true)}>+ Crear cuenta</button>}
      {creating && <CreateAccount onCancel={() => setCreating(false)} onDone={() => { setCreating(false); setMessage("Cuenta de ahorro creada correctamente."); }} />}
      {active.length > 0 && <AccountList accounts={active} currency={settings!.currency} />}
      {pending.length > 0 && <details className="savings-inactive">
        <summary>Cuentas por revisar · {pending.length}<span aria-hidden="true">⌄</span></summary>
        <p className="muted">Estas cuentas inactivas antiguas aún conservan saldo. Revísalas para que ese dinero no quede oculto.</p>
        <AccountList accounts={pending} currency={settings!.currency} />
      </details>}
    </>)}
  </div>;
}
