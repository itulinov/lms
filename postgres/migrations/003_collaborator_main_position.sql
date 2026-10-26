-- Основная должность — в сотруднике, история закреплений — триггерами.
--
-- Должность — штатная единица под постоянным uuid, она не удаляется.
-- Сотрудник может занимать несколько должностей, должность — не больше
-- одного сотрудника. Основная должность сотрудника теперь
-- collaborators.main_position_id (в WebSoft — collaborator.position_id),
-- positions.is_main убирается.
--
-- Прикрепление, открепление и смена основной должности пишутся в
-- collaborator_position_history триггерами. Увольнение и закрытие
-- должности сотрудника не открепляют.


-- Представление читает positions.is_main — вернём его в конце.
DROP VIEW v_collaborators;


-- assignment_start_date — с какой даты занята текущим сотрудником,
-- assignment_finish_date — с какой даты вакантна. Ставятся вместе со
-- сменой collaborator_id; без даты берётся current_date.
-- start_date / finish_date остаются сроком жизни штатной единицы.
ALTER TABLE positions
    ADD COLUMN assignment_start_date date,
    ADD COLUMN assignment_finish_date date,
    ADD UNIQUE ( id, collaborator_id );

-- Составной ключ: основная должность принадлежит этому же сотруднику.
-- Одно поле — одна основная должность.
ALTER TABLE collaborators
    ADD COLUMN main_position_id uuid,
    ADD FOREIGN KEY ( main_position_id, id )
        REFERENCES positions ( id, collaborator_id );

UPDATE collaborators c
SET main_position_id = p.id
FROM positions p
WHERE p.collaborator_id = c.id
    AND p.is_main;

-- Вместе с колонкой уходят частичный уникальный индекс и проверка
-- NOT is_main OR collaborator_id IS NOT NULL.
ALTER TABLE positions DROP COLUMN is_main;


-- date — кадровая дата события, created_at — время записи. created_at
-- из clock_timestamp(): события одной транзакции идут в порядке записи.
-- Удаление сотрудника больше не стирает его историю.
ALTER TABLE collaborator_position_history
    ALTER COLUMN date TYPE date,
    ADD COLUMN event_type text NOT NULL
        CHECK ( event_type IN (
            'assigned', 'unassigned', 'main_set', 'main_unset' ) ),
    ADD COLUMN created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    DROP CONSTRAINT collaborator_position_history_collaborator_id_fkey,
    ADD FOREIGN KEY ( collaborator_id ) REFERENCES collaborators;

CREATE INDEX ON collaborator_position_history ( position_id );


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
