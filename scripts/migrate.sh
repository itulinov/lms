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

# Ключ advisory-блокировки: два одновременных запуска не применят одну
# миграцию дважды — второй дождётся первого и упадёт на записи в журнал.
lock_key=20260101

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

    {
        echo "DO \$\$ BEGIN PERFORM pg_advisory_xact_lock($lock_key); END \$\$;"
        echo "INSERT INTO public.schema_migrations ( version )"
        echo "VALUES ( '$version' );"
        cat "$file"
    } | psql_db --single-transaction -f -

    count=$((count + 1))
done

echo "Готово, применено миграций: $count"
