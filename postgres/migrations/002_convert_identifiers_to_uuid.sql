-- Перевод идентификаторов с bigint на uuid v4 (тот же формат, что у
-- uuidgen). Новые записи получают id из gen_random_uuid().
--
-- id WebSoft больше не переносятся в id: соответствие хранится в
-- websoft_ids, и весь импорт идёт через неё.
--
-- Только для пустых таблиц: значения ссылок не сохраняются. Запускать
-- одной транзакцией (psql --single-transaction).

LOCK TABLE
    orgs,
    cost_centers,
    subdivisions,
    boss_types,
    position_commons,
    collaborators,
    positions,
    func_managers,
    collaborator_position_history,
    collaborator_states
IN ACCESS EXCLUSIVE MODE;

DO $$
DECLARE
    tbl       text;
    has_rows  boolean;
BEGIN
    FOREACH tbl IN ARRAY ARRAY[
        'orgs',
        'cost_centers',
        'subdivisions',
        'boss_types',
        'position_commons',
        'collaborators',
        'positions',
        'func_managers',
        'collaborator_position_history',
        'collaborator_states'
    ] LOOP
        EXECUTE format( 'SELECT EXISTS ( SELECT 1 FROM %I )', tbl )
            INTO has_rows;

        IF has_rows THEN
            RAISE EXCEPTION 'Таблица % содержит данные', tbl;
        END IF;
    END LOOP;
END;
$$;


-- Представление и внешние ключи мешают смене типа — снимаем и вернём
-- в конце.
DROP VIEW v_collaborators;

ALTER TABLE cost_centers
    DROP CONSTRAINT cost_centers_parent_id_fkey;

ALTER TABLE subdivisions
    DROP CONSTRAINT subdivisions_org_id_fkey,
    DROP CONSTRAINT subdivisions_parent_id_fkey,
    DROP CONSTRAINT subdivisions_cost_center_id_fkey;

ALTER TABLE collaborators
    DROP CONSTRAINT collaborators_cost_center_id_fkey;

ALTER TABLE positions
    DROP CONSTRAINT positions_subdivision_id_fkey,
    DROP CONSTRAINT positions_collaborator_id_fkey,
    DROP CONSTRAINT positions_position_common_id_fkey;

ALTER TABLE func_managers
    DROP CONSTRAINT func_managers_person_id_fkey,
    DROP CONSTRAINT func_managers_boss_type_id_fkey,
    DROP CONSTRAINT func_managers_collaborator_id_fkey,
    DROP CONSTRAINT func_managers_subdivision_id_fkey,
    DROP CONSTRAINT func_managers_org_id_fkey,
    DROP CONSTRAINT func_managers_cost_center_id_fkey;

ALTER TABLE collaborator_position_history
    DROP CONSTRAINT collaborator_position_history_collaborator_id_fkey;

ALTER TABLE collaborator_states
    DROP CONSTRAINT collaborator_states_collaborator_id_fkey;


-- Первичные ключи. USING не важен — таблицы пусты.
ALTER TABLE orgs
    ALTER COLUMN id DROP IDENTITY,
    ALTER COLUMN id TYPE uuid USING gen_random_uuid(),
    ALTER COLUMN id SET DEFAULT gen_random_uuid();

ALTER TABLE cost_centers
    ALTER COLUMN id DROP IDENTITY,
    ALTER COLUMN id TYPE uuid USING gen_random_uuid(),
    ALTER COLUMN id SET DEFAULT gen_random_uuid(),
    ALTER COLUMN parent_id TYPE uuid USING NULL;

ALTER TABLE subdivisions
    ALTER COLUMN id DROP IDENTITY,
    ALTER COLUMN id TYPE uuid USING gen_random_uuid(),
    ALTER COLUMN id SET DEFAULT gen_random_uuid(),
    ALTER COLUMN org_id TYPE uuid USING NULL,
    ALTER COLUMN parent_id TYPE uuid USING NULL,
    ALTER COLUMN cost_center_id TYPE uuid USING NULL;

ALTER TABLE boss_types
    ALTER COLUMN id DROP IDENTITY,
    ALTER COLUMN id TYPE uuid USING gen_random_uuid(),
    ALTER COLUMN id SET DEFAULT gen_random_uuid();

ALTER TABLE position_commons
    ALTER COLUMN id DROP IDENTITY,
    ALTER COLUMN id TYPE uuid USING gen_random_uuid(),
    ALTER COLUMN id SET DEFAULT gen_random_uuid();

ALTER TABLE collaborators
    ALTER COLUMN id DROP IDENTITY,
    ALTER COLUMN id TYPE uuid USING gen_random_uuid(),
    ALTER COLUMN id SET DEFAULT gen_random_uuid(),
    ALTER COLUMN cost_center_id TYPE uuid USING NULL;

ALTER TABLE positions
    ALTER COLUMN id DROP IDENTITY,
    ALTER COLUMN id TYPE uuid USING gen_random_uuid(),
    ALTER COLUMN id SET DEFAULT gen_random_uuid(),
    ALTER COLUMN subdivision_id TYPE uuid USING NULL,
    ALTER COLUMN collaborator_id TYPE uuid USING NULL,
    ALTER COLUMN position_common_id TYPE uuid USING NULL;

ALTER TABLE func_managers
    ALTER COLUMN id DROP IDENTITY,
    ALTER COLUMN id TYPE uuid USING gen_random_uuid(),
    ALTER COLUMN id SET DEFAULT gen_random_uuid(),
    ALTER COLUMN person_id TYPE uuid USING NULL,
    ALTER COLUMN boss_type_id TYPE uuid USING NULL,
    ALTER COLUMN collaborator_id TYPE uuid USING NULL,
    ALTER COLUMN subdivision_id TYPE uuid USING NULL,
    ALTER COLUMN org_id TYPE uuid USING NULL,
    ALTER COLUMN cost_center_id TYPE uuid USING NULL;

ALTER TABLE collaborator_position_history
    ALTER COLUMN id DROP IDENTITY,
    ALTER COLUMN id TYPE uuid USING gen_random_uuid(),
    ALTER COLUMN id SET DEFAULT gen_random_uuid(),
    ALTER COLUMN collaborator_id TYPE uuid USING NULL,
    ALTER COLUMN position_id TYPE uuid USING NULL,
    ALTER COLUMN subdivision_id TYPE uuid USING NULL,
    ALTER COLUMN org_id TYPE uuid USING NULL;

ALTER TABLE collaborator_states
    ALTER COLUMN id DROP IDENTITY,
    ALTER COLUMN id TYPE uuid USING gen_random_uuid(),
    ALTER COLUMN id SET DEFAULT gen_random_uuid(),
    ALTER COLUMN collaborator_id TYPE uuid USING NULL;


-- Внешние ключи — с прежними правилами удаления.
ALTER TABLE cost_centers
    ADD FOREIGN KEY ( parent_id ) REFERENCES cost_centers;

ALTER TABLE subdivisions
    ADD FOREIGN KEY ( org_id ) REFERENCES orgs,
    ADD FOREIGN KEY ( parent_id ) REFERENCES subdivisions,
    ADD FOREIGN KEY ( cost_center_id ) REFERENCES cost_centers;

ALTER TABLE collaborators
    ADD FOREIGN KEY ( cost_center_id ) REFERENCES cost_centers;

ALTER TABLE positions
    ADD FOREIGN KEY ( subdivision_id ) REFERENCES subdivisions,
    ADD FOREIGN KEY ( collaborator_id ) REFERENCES collaborators,
    ADD FOREIGN KEY ( position_common_id ) REFERENCES position_commons;

ALTER TABLE func_managers
    ADD FOREIGN KEY ( person_id ) REFERENCES collaborators,
    ADD FOREIGN KEY ( boss_type_id ) REFERENCES boss_types,
    ADD FOREIGN KEY ( collaborator_id )
        REFERENCES collaborators ON DELETE CASCADE,
    ADD FOREIGN KEY ( subdivision_id )
        REFERENCES subdivisions ON DELETE CASCADE,
    ADD FOREIGN KEY ( org_id ) REFERENCES orgs ON DELETE CASCADE,
    ADD FOREIGN KEY ( cost_center_id )
        REFERENCES cost_centers ON DELETE CASCADE;

ALTER TABLE collaborator_position_history
    ADD FOREIGN KEY ( collaborator_id )
        REFERENCES collaborators ON DELETE CASCADE;

ALTER TABLE collaborator_states
    ADD FOREIGN KEY ( collaborator_id )
        REFERENCES collaborators ON DELETE CASCADE;


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
