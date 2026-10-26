#!/usr/bin/env bash
# Сверяет postgres/schema.sql с результатом миграций из
# postgres/migrations: обе схемы разворачиваются во временных базах в
# контейнере db, затем сравниваются колонки, ограничения, индексы,
# триггеры, функции и представления. Порядок колонок не учитывается:
# миграции добавляют колонки в конец таблицы, в schema.sql они стоят
# по смыслу.
#
# Рабочую базу lms не трогает. Временные базы удаляются при выходе.
#
# Запуск из любого каталога: ./scripts/check-schema.sh

set -euo pipefail

cd "$(dirname "$0")/.."

db_schema="lms_check_schema"
db_migr="lms_check_migr"
tmp_dir=$(mktemp -d)

psql_db() {
    docker compose exec -T db \
        psql -X -q -v ON_ERROR_STOP=1 -U lms "$@"
}

cleanup() {
    psql_db -d lms \
        -c "DROP DATABASE IF EXISTS $db_schema" \
        -c "DROP DATABASE IF EXISTS $db_migr"
    rm -rf "$tmp_dir"
}

trap cleanup EXIT

cat > "$tmp_dir/catalog.sql" <<'SQL'
SELECT 'column', table_name || '.' || column_name,
    data_type
    || ' null=' || is_nullable
    || ' default=' || coalesce( column_default, '' )
    || ' generated=' || coalesce( generation_expression, '' )
    || ' identity=' || is_identity
FROM information_schema.columns
WHERE table_schema = 'public'
UNION ALL
SELECT 'constraint', conrelid::regclass || '.' || conname,
    pg_get_constraintdef( oid )
FROM pg_constraint
WHERE connamespace = 'public'::regnamespace
UNION ALL
SELECT 'index', indexname, indexdef
FROM pg_indexes
WHERE schemaname = 'public'
UNION ALL
SELECT 'trigger', tgrelid::regclass || '.' || tgname,
    pg_get_triggerdef( oid )
FROM pg_trigger
WHERE NOT tgisinternal
UNION ALL
SELECT 'function', proname, pg_get_functiondef( oid )
FROM pg_proc
WHERE pronamespace = 'public'::regnamespace
UNION ALL
SELECT 'view', viewname, definition
FROM pg_views
WHERE schemaname = 'public'
ORDER BY 1, 2;
SQL

psql_db -d lms \
    -c "DROP DATABASE IF EXISTS $db_schema" \
    -c "DROP DATABASE IF EXISTS $db_migr" \
    -c "CREATE DATABASE $db_schema" \
    -c "CREATE DATABASE $db_migr"

echo "Разворачиваю schema.sql"
psql_db -d "$db_schema" --single-transaction -f - < postgres/schema.sql

for file in postgres/migrations/*.sql; do
    echo "Применяю $(basename "$file" .sql)"
    psql_db -d "$db_migr" --single-transaction -f - < "$file"
done

psql_db -d "$db_schema" -At -F ' | ' -f - \
    < "$tmp_dir/catalog.sql" > "$tmp_dir/schema.txt"
psql_db -d "$db_migr" -At -F ' | ' -f - \
    < "$tmp_dir/catalog.sql" > "$tmp_dir/migr.txt"

if [[ ! -s "$tmp_dir/schema.txt" || ! -s "$tmp_dir/migr.txt" ]]; then
    echo "Каталог пуст — сравнивать нечего" >&2
    exit 1
fi

echo "Строк: schema.sql $(wc -l < "$tmp_dir/schema.txt")," \
    "миграции $(wc -l < "$tmp_dir/migr.txt")"

if ! diff "$tmp_dir/schema.txt" "$tmp_dir/migr.txt"; then
    echo "Схемы расходятся (< schema.sql, > миграции)" >&2
    exit 1
fi

echo "Схемы совпадают"
