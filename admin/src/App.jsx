import { useEffect, useState } from 'react';

export default function App() {
  const [health, setHealth] = useState({ loading: true });

  async function checkApi() {
    setHealth({ loading: true });
    try {
      const response = await fetch('/api/health', { cache: 'no-store' });
      const data = await response.json();
      setHealth({ ...data, httpOk: response.ok, loading: false });
    } catch (error) {
      setHealth({ loading: false, httpOk: false, error: error.message });
    }
  }

  useEffect(() => { checkApi(); }, []);

  const ready = health.httpOk && health.status === 'ok' && health.database === 'connected';

  return (
    <div className="layout">
      <aside className="sidebar">
        <div className="brand">Corporate LMS <small>Администрирование</small></div>
        <nav aria-label="Главное меню">
          <a className="active" href="#dashboard">Главная</a>
          <span>Сотрудники — скоро</span>
          <span>Курсы — скоро</span>
          <span>Назначения — скоро</span>
          <span>Настройки — скоро</span>
        </nav>
      </aside>
      <main id="dashboard" className="content">
        <div className="eyebrow">Административная панель</div>
        <h1>Добро пожаловать в LMS</h1>
        <p className="intro">Первый рабочий экран админки на React + Vite. Портал сотрудников остаётся без изменений.</p>
        <section className="panel">
          <h2>Состояние Go API</h2>
          {health.loading ? (
            <p>Проверка соединения…</p>
          ) : ready ? (
            <p className="success">● API работает · PostgreSQL подключён</p>
          ) : (
            <p className="error">● Ошибка проверки API или БД: {health.error || JSON.stringify(health)}</p>
          )}
          <button onClick={checkApi}>Проверить снова</button>
          <p className="note">Запрос идёт по относительному адресу <code>/api/health</code> через Nginx к Go.</p>
        </section>
      </main>
    </div>
  );
}
