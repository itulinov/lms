#!/usr/bin/env bash
# Применяет к базе в контейнере db миграции из postgres/migrations,
# которых ещё нет в журнале schema_migrations.
#
# Каждая миграция — отдельная транзакция: запись в журнал и сам SQL
# фиксируются вместе или откатываются вместе. При ошибке скрипт
# останавливается, следующие миграции не запускаются.
#
# Запуск из любого каталога: ./scripts/migrate.sh

set -euo pipefail

cd "$(dirname "$0")/.."

# Ключ advisory-блокировки. Одновременные запуски выполняют миграции по
# очереди: получив блокировку, процесс заново смотрит журнал и пропускает
# миграцию, если её уже применил другой.
lock_key=20260101
skip_mark="MIGRATION_ALREADY_APPLIED"

psql_db() {
    docker compose exec -T db \
        psql -X -q -v ON_ERROR_STOP=1 -U lms -d lms "$@"
}

psql_db <<'SQL'
CREATE TABLE IF NOT EXISTS public.schema_migrations (
    version     text PRIMARY KEY,
    applied_at  timestamptz NOT NULL DEFAULT now()
);
SQL

applied=$(psql_db -At -c "SELECT version FROM public.schema_migrations")

count=0
for file in postgres/migrations/*.sql; do
    version=$(basename "$file" .sql)

    if grep -qxF "$version" <<< "$applied"; then
        continue
    fi

    echo "Применяю $version"

    # Блокировка, повторная проверка журнала, запись версии и SQL
    # миграции — в одной транзакции.
    out=$(
        {
            echo "SELECT pg_advisory_xact_lock($lock_key) \\gset"
            echo "SELECT EXISTS ("
            echo "    SELECT 1 FROM public.schema_migrations"
            echo "    WHERE version = '$version'"
            echo ") AS is_applied \\gset"
            echo "\\if :is_applied"
            echo "\\echo $skip_mark"
            echo "\\else"
            echo "INSERT INTO public.schema_migrations ( version )"
            echo "VALUES ( '$version' );"
            cat "$file"
            echo
            echo "\\endif"
        } | psql_db --single-transaction -f -
    )

    if [[ "$out" == "$skip_mark" ]]; then
        echo "  уже применена другим процессом, пропускаю"
        continue
    fi

    if [[ -n "$out" ]]; then
        echo "$out"
    fi

    count=$((count + 1))
done

echo "Готово, применено миграций: $count"
