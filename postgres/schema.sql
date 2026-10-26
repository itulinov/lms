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


-- Сотрудник. Должностей может быть несколько — они в positions;
-- main_position_id — основная из них (в WebSoft collaborator.position_id),
-- ключ на неё добавлен после positions (см. v_collaborators).
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
    main_position_id  uuid,
    data            jsonb NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);


-- Должность — штатная единица в подразделении, занятая одним
-- сотрудником или вакантная. Не удаляется (триггер forbid_delete):
-- должность закрывают статусом, сотрудника открепляют, а прежние
-- закрепления остаются в collaborator_position_history.
-- assignment_start_date — с какой даты занята текущим сотрудником,
-- assignment_finish_date — с какой даты вакантна. Ставятся вместе со
-- сменой collaborator_id; без даты берётся current_date.
-- start_date / finish_date — срок жизни штатной единицы.
-- data: custom {}.
CREATE TABLE positions (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                text,
    name                text NOT NULL,
    subdivision_id      uuid NOT NULL REFERENCES subdivisions,
    collaborator_id     uuid REFERENCES collaborators,
    position_common_id  uuid REFERENCES position_commons,
    is_boss             boolean NOT NULL DEFAULT false,
    status              text NOT NULL DEFAULT 'active'
        CHECK ( status IN ( 'active', 'plan', 'project', 'close', 'cancel' ) ),
    start_date          date,
    finish_date         date,
    assignment_start_date   date,
    assignment_finish_date  date,
    data                jsonb NOT NULL DEFAULT '{}',
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    UNIQUE ( id, collaborator_id )
);

CREATE INDEX ON positions ( subdivision_id );
CREATE INDEX ON positions ( collaborator_id );

-- Составной ключ: основная должность принадлежит этому же сотруднику.
ALTER TABLE collaborators
    ADD FOREIGN KEY ( main_position_id, id )
        REFERENCES positions ( id, collaborator_id );


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


-- История закреплений (change_logs в WebSoft): прикрепление,
-- открепление, смена основной должности; пишется триггерами. Названия —
-- снимок на дату события, поэтому хранятся тут же; на должность внешнего
-- ключа нет: в WebSoft старые должности могли быть удалены.
-- date — кадровая дата события, created_at — время записи; created_at
-- из clock_timestamp(): события одной транзакции идут в порядке записи.
CREATE TABLE collaborator_position_history (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    collaborator_id   uuid NOT NULL REFERENCES collaborators,
    event_type        text NOT NULL
        CHECK ( event_type IN (
            'assigned', 'unassigned', 'main_set', 'main_unset' ) ),
    date              date NOT NULL,
    position_id       uuid,
    position_name     text,
    subdivision_id    uuid,
    subdivision_name  text,
    org_id            uuid,
    org_name          text,
    comment           text,
    created_at        timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX ON collaborator_position_history ( collaborator_id );
CREATE INDEX ON collaborator_position_history ( position_id );


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


-- Запись события со снимком названий должности, подразделения и
-- организации.
CREATE FUNCTION log_position_event(
    p_event_type       text,
    p_collaborator_id  uuid,
    p_position         positions,
    p_date             date
) RETURNS void
LANGUAGE sql AS $$
    INSERT INTO collaborator_position_history (
        collaborator_id,
        event_type,
        date,
        position_id,
        position_name,
        subdivision_id,
        subdivision_name,
        org_id,
        org_name
    )
    SELECT
        p_collaborator_id,
        p_event_type,
        p_date,
        p_position.id,
        p_position.name,
        s.id,
        s.name,
        o.id,
        o.name
    FROM subdivisions s
    JOIN orgs o ON o.id = s.org_id
    WHERE s.id = p_position.subdivision_id;
$$;


-- Физическое удаление запрещено: должность закрывают статусом, сотрудника
-- открепляют.
CREATE FUNCTION forbid_delete() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Удаление из % запрещено', TG_TABLE_NAME;
END;
$$;


-- Смена collaborator_id: открепление прежнего сотрудника и прикрепление
-- нового, с датами из assignment_*_date, если их поменяли в том же
-- запросе. Даты занятой должности без смены сотрудника не меняются —
-- иначе они разойдутся с историей.
CREATE FUNCTION positions_assignment() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    old_collaborator_id  uuid;
    old_start_date       date;
    old_finish_date      date;
    assign_date          date := current_date;
    unassign_date        date := current_date;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        old_collaborator_id := OLD.collaborator_id;
        old_start_date := OLD.assignment_start_date;
        old_finish_date := OLD.assignment_finish_date;
    END IF;

    IF NEW.collaborator_id IS NOT DISTINCT FROM old_collaborator_id THEN
        IF NEW.collaborator_id IS NOT NULL AND (
            NEW.assignment_start_date IS DISTINCT FROM old_start_date
            OR NEW.assignment_finish_date IS DISTINCT FROM old_finish_date
        ) THEN
            RAISE EXCEPTION
                'Даты закрепления меняются только вместе с сотрудником';
        END IF;

        RETURN NEW;
    END IF;

    IF NEW.assignment_start_date IS DISTINCT FROM old_start_date THEN
        assign_date := coalesce( NEW.assignment_start_date, current_date );
    END IF;

    IF NEW.assignment_finish_date IS DISTINCT FROM old_finish_date THEN
        unassign_date := coalesce( NEW.assignment_finish_date, current_date );
    END IF;

    IF old_collaborator_id IS NOT NULL THEN
        PERFORM log_position_event(
            'unassigned', old_collaborator_id, OLD, unassign_date );

        -- До записи строки: пока должность за прежним сотрудником, ключ
        -- main_position_id ещё действителен, а снимок для main_unset —
        -- прежний.
        UPDATE collaborators
        SET main_position_id = NULL
        WHERE id = old_collaborator_id
            AND main_position_id = OLD.id;
    END IF;

    IF NEW.collaborator_id IS NULL THEN
        NEW.assignment_start_date := NULL;
        NEW.assignment_finish_date := unassign_date;
        RETURN NEW;
    END IF;

    NEW.assignment_start_date := assign_date;
    NEW.assignment_finish_date := NULL;
    PERFORM log_position_event(
        'assigned', NEW.collaborator_id, NEW, assign_date );

    RETURN NEW;
END;
$$;


-- Единственная должность сотрудника без основной становится основной.
-- AFTER: составной ключ проверяет уже записанную строку должности.
CREATE FUNCTION positions_set_main() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.collaborator_id IS NULL THEN
        RETURN NULL;
    END IF;

    IF TG_OP = 'UPDATE'
        AND NEW.collaborator_id IS NOT DISTINCT FROM OLD.collaborator_id
    THEN
        RETURN NULL;
    END IF;

    UPDATE collaborators c
    SET main_position_id = NEW.id
    WHERE c.id = NEW.collaborator_id
        AND c.main_position_id IS NULL
        AND (
            SELECT count(*) FROM positions p
            WHERE p.collaborator_id = c.id
        ) = 1;

    RETURN NULL;
END;
$$;


-- Смена основной должности: main_unset по прежней, main_set по новой.
CREATE FUNCTION collaborators_main_position_log() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    pos  positions;
BEGIN
    IF OLD.main_position_id IS NOT NULL THEN
        SELECT * INTO pos FROM positions WHERE id = OLD.main_position_id;
        PERFORM log_position_event( 'main_unset', NEW.id, pos, current_date );
    END IF;

    IF NEW.main_position_id IS NOT NULL THEN
        SELECT * INTO pos FROM positions WHERE id = NEW.main_position_id;
        PERFORM log_position_event( 'main_set', NEW.id, pos, current_date );
    END IF;

    RETURN NULL;
END;
$$;


CREATE TRIGGER forbid_delete BEFORE DELETE ON positions
    FOR EACH ROW EXECUTE FUNCTION forbid_delete();
CREATE TRIGGER positions_assignment BEFORE INSERT OR UPDATE ON positions
    FOR EACH ROW EXECUTE FUNCTION positions_assignment();
CREATE TRIGGER positions_set_main
    AFTER INSERT OR UPDATE OF collaborator_id ON positions
    FOR EACH ROW EXECUTE FUNCTION positions_set_main();
CREATE TRIGGER main_position_log
    AFTER UPDATE OF main_position_id ON collaborators
    FOR EACH ROW
    WHEN ( OLD.main_position_id IS DISTINCT FROM NEW.main_position_id )
    EXECUTE FUNCTION collaborators_main_position_log();


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
LEFT JOIN positions p ON p.id = c.main_position_id
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
--       FROM collaborators c
--       JOIN positions p ON p.id = c.main_position_id
--       JOIN subdivisions s ON s.id = p.subdivision_id
--       WHERE c.id = :person_id
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
