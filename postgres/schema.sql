-- Оргструктура и сотрудники: аналог каталогов WebSoft HCM на PostgreSQL.
--
-- Ключи, ссылки, статусы и даты — колонками; остальное — в data jsonb.
-- id — uuid v4 из gen_random_uuid() (формат uuidgen). id WebSoft сюда не
-- переносятся: соответствие id WebSoft и uuid хранится в websoft_ids.
--
-- Индексы — только на ссылках, по которым идут частые выборки. PostgreSQL
-- не индексирует внешние ключи сам.

CREATE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;


-- Организация — корень структуры.
-- data: postal_address, phone, fax, essentials[] (inn, kpp, ogrn, адреса,
-- director, chief_accountant, bank_account[]), custom {}.
CREATE TABLE orgs (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code        text,
    name        text NOT NULL,
    disp_name   text,
    data        jsonb NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);


-- Центр затрат, дерево через parent_id.
CREATE TABLE cost_centers (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code        text,
    name        text NOT NULL,
    parent_id   uuid REFERENCES cost_centers,
    is_active   boolean NOT NULL DEFAULT true,
    data        jsonb NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);


-- Подразделение. Дерево через parent_id; у корневого parent_id пуст,
-- над ним стоит организация (org_id есть у каждого узла).
-- data: comment, desc, custom {}.
CREATE TABLE subdivisions (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code            text,
    name            text NOT NULL,
    org_id          uuid NOT NULL REFERENCES orgs,
    parent_id       uuid REFERENCES subdivisions,
    status          text NOT NULL DEFAULT 'active'
        CHECK ( status IN ( 'active', 'plan', 'project', 'close', 'cancel' ) ),
    is_disbanded    boolean NOT NULL DEFAULT false,
    formed_date     date,
    disbanded_date  date,
    cost_center_id  uuid REFERENCES cost_centers,
    data            jsonb NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ON subdivisions ( parent_id );


-- Тип руководителя: main — непосредственный, остальные — функциональные.
-- В WebSoft ссылки на тип идут по id — при импорте сопоставляются через
-- websoft_ids.
CREATE TABLE boss_types (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code        text UNIQUE,
    name        text NOT NULL,
    data        jsonb NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);


-- Типовая должность — справочник «должность как понятие».
-- data: вилка окладов, грейды, уровни, custom {}.
CREATE TABLE position_commons (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code        text,
    name        text NOT NULL,
    status      text NOT NULL DEFAULT 'active'
        CHECK ( status IN ( 'active', 'archive', 'plan' ) ),
    data        jsonb NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);


-- Сотрудник. Должность и подразделение здесь не хранятся — они приходят
-- через positions (см. v_collaborators).
-- data: phone, mobile_phone, snils, pict_url, custom {} (custom_elems
-- WebSoft: массив пар name/value превращается в объект).
CREATE TABLE collaborators (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code            text,
    login           text UNIQUE,
    lastname        text NOT NULL,
    firstname       text,
    middlename      text,
    fullname        text GENERATED ALWAYS AS (
        lastname
        || coalesce( ' ' || firstname, '' )
        || coalesce( ' ' || middlename, '' )
    ) STORED,
    email           text,
    sex             text,
    birth_date      date,
    hire_date       date,
    dismiss_date    date,
    is_dismiss      boolean NOT NULL DEFAULT false,
    cost_center_id  uuid REFERENCES cost_centers,
    data            jsonb NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);


-- Должность — конкретное место в подразделении, занятое одним
-- сотрудником или вакантное. После ухода сотрудника запись остаётся:
-- на неё ссылается история переводов.
-- is_main — основная должность сотрудника (в WebSoft это
-- collaborator.position_id); у человека она одна.
-- data: custom {}.
CREATE TABLE positions (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                text,
    name                text NOT NULL,
    subdivision_id      uuid NOT NULL REFERENCES subdivisions,
    collaborator_id     uuid REFERENCES collaborators,
    is_main             boolean NOT NULL DEFAULT false,
    position_common_id  uuid REFERENCES position_commons,
    is_boss             boolean NOT NULL DEFAULT false,
    status              text NOT NULL DEFAULT 'active'
        CHECK ( status IN ( 'active', 'plan', 'project', 'close', 'cancel' ) ),
    start_date          date,
    finish_date         date,
    data                jsonb NOT NULL DEFAULT '{}',
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    CHECK ( NOT is_main OR collaborator_id IS NOT NULL )
);

CREATE INDEX ON positions ( subdivision_id );
CREATE INDEX ON positions ( collaborator_id );
CREATE UNIQUE INDEX ON positions ( collaborator_id ) WHERE is_main;


-- Руководитель объекта: сотрудника, подразделения, организации или
-- центра затрат — заполнена ровно одна из четырёх ссылок.
-- В WebSoft это массив func_managers внутри карточки объекта.
CREATE TABLE func_managers (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    person_id        uuid NOT NULL REFERENCES collaborators,
    boss_type_id     uuid REFERENCES boss_types,
    collaborator_id  uuid REFERENCES collaborators ON DELETE CASCADE,
    subdivision_id   uuid REFERENCES subdivisions ON DELETE CASCADE,
    org_id           uuid REFERENCES orgs ON DELETE CASCADE,
    cost_center_id   uuid REFERENCES cost_centers ON DELETE CASCADE,
    is_native        boolean NOT NULL DEFAULT false,
    start_date       date,
    end_date         date,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CHECK ( num_nonnulls(
        collaborator_id, subdivision_id, org_id, cost_center_id ) = 1 )
);

CREATE INDEX ON func_managers ( person_id );
CREATE INDEX ON func_managers ( subdivision_id );
CREATE INDEX ON func_managers ( collaborator_id );


-- История переводов (change_logs в WebSoft). Названия — снимок на дату
-- перевода, поэтому хранятся тут же; на должность внешнего ключа нет:
-- старые должности могли быть удалены.
CREATE TABLE collaborator_position_history (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    collaborator_id   uuid NOT NULL
        REFERENCES collaborators ON DELETE CASCADE,
    date              timestamptz NOT NULL,
    position_id       uuid,
    position_name     text,
    subdivision_id    uuid,
    subdivision_name  text,
    org_id            uuid,
    org_name          text,
    comment           text
);

CREATE INDEX ON collaborator_position_history ( collaborator_id );


-- Состояния сотрудника: отпуск, больничный и т. п. (history_states).
-- state — значение настраиваемого справочника, в WebSoft это текст.
CREATE TABLE collaborator_states (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    collaborator_id  uuid NOT NULL
        REFERENCES collaborators ON DELETE CASCADE,
    state            text NOT NULL,
    start_date       date NOT NULL,
    finish_date      date,
    comment          text
);

CREATE INDEX ON collaborator_states ( collaborator_id );


CREATE TRIGGER set_updated_at BEFORE UPDATE ON orgs
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON cost_centers
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON subdivisions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON boss_types
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON position_commons
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON collaborators
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON positions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON func_managers
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- Соответствие id WebSoft и uuid LMS. Импорт идёт только через неё:
-- сначала INSERT ... ON CONFLICT DO NOTHING, затем берётся id — повторный
-- импорт той же записи получает тот же uuid. id WebSoft уникальны во
-- всех каталогах, поэтому ключ — один websoft_id.
-- catalog — имя таблицы LMS (collaborators, subdivisions, ...); внешнего
-- ключа на целевую таблицу нет, он зависел бы от catalog.
--
--   INSERT INTO websoft_ids ( websoft_id, catalog )
--   VALUES ( :websoft_id, 'collaborators' )
--   ON CONFLICT DO NOTHING;
--
--   SELECT id FROM websoft_ids WHERE websoft_id = :websoft_id;
CREATE TABLE websoft_ids (
    websoft_id  bigint PRIMARY KEY,
    catalog     text NOT NULL,
    id          uuid NOT NULL DEFAULT gen_random_uuid(),
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE ( catalog, id )
);


-- Аналог каталога collaborators WebSoft: сотрудник с основной
-- должностью, подразделением и организацией.
CREATE VIEW v_collaborators AS
SELECT
    c.id,
    c.code,
    c.fullname,
    c.login,
    c.email,
    c.hire_date,
    c.dismiss_date,
    c.is_dismiss,
    p.id    AS position_id,
    p.name  AS position_name,
    s.id    AS position_parent_id,
    s.name  AS position_parent_name,
    o.id    AS org_id,
    o.name  AS org_name
FROM collaborators c
LEFT JOIN positions p ON p.collaborator_id = c.id AND p.is_main
LEFT JOIN subdivisions s ON s.id = p.subdivision_id
LEFT JOIN orgs o ON o.id = s.org_id;


-- Примеры запросов (psql, параметры через :имя).
--
-- Сотрудники подразделения вместе с дочерними:
--
--   WITH RECURSIVE tree AS (
--       SELECT id FROM subdivisions WHERE id = :sub_id
--       UNION ALL
--       SELECT s.id FROM subdivisions s JOIN tree t ON s.parent_id = t.id
--   )
--   SELECT c.*
--   FROM tree
--   JOIN positions p ON p.subdivision_id = tree.id
--   JOIN collaborators c ON c.id = p.collaborator_id;
--
-- Непосредственный руководитель сотрудника: сначала назначенный ему
-- лично (depth 0), иначе ближайший при подъёме по подразделениям.
-- Тип — main или не указан (как трактовать пустой тип — уточнить).
--
--   WITH RECURSIVE up AS (
--       SELECT s.id, s.parent_id, 1 AS depth
--       FROM positions p
--       JOIN subdivisions s ON s.id = p.subdivision_id
--       WHERE p.collaborator_id = :person_id AND p.is_main
--       UNION ALL
--       SELECT s.id, s.parent_id, up.depth + 1
--       FROM subdivisions s JOIN up ON s.id = up.parent_id
--   ),
--   candidates AS (
--       SELECT fm.person_id, fm.boss_type_id, 0 AS depth
--       FROM func_managers fm
--       WHERE fm.collaborator_id = :person_id
--       UNION ALL
--       SELECT fm.person_id, fm.boss_type_id, up.depth
--       FROM up JOIN func_managers fm ON fm.subdivision_id = up.id
--   )
--   SELECT cd.person_id
--   FROM candidates cd
--   LEFT JOIN boss_types bt ON bt.id = cd.boss_type_id
--   WHERE cd.person_id <> :person_id
--       AND ( bt.code = 'main' OR cd.boss_type_id IS NULL )
--   ORDER BY cd.depth
--   FETCH FIRST 1 ROWS WITH TIES;
--
-- Поиск по настраиваемому полю (без индекса — полный просмотр):
--
--   SELECT id, fullname FROM collaborators
--   WHERE data -> 'custom' ->> 'NFS_EMP_NO' = :emp_no;
