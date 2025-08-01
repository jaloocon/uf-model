
-- Tabla UF base (semilla única)
CREATE TABLE IF NOT EXISTS uf_base (
    fecha DATE PRIMARY KEY,
    valor NUMERIC(12, 4) NOT NULL
);

-- Tabla de variaciones mensuales del IPC (como porcentaje)
CREATE TABLE IF NOT EXISTS ipc_variacion_mensual (
    anio SMALLINT NOT NULL,
    mes  SMALLINT NOT NULL,
    variacion_mensual_pct NUMERIC(6,3) NOT NULL,
    PRIMARY KEY (anio, mes),
    CHECK (variacion_mensual_pct > -100)
);

-- Tabla UF diaria generada automáticamente
CREATE TABLE IF NOT EXISTS uf_diaria (
    fecha DATE PRIMARY KEY,
    valor NUMERIC(12, 2) NOT NULL
);

-- Función para recalcular UF diaria desde un mes dado
CREATE OR REPLACE FUNCTION recalcular_uf_desde(inicio_anio SMALLINT, inicio_mes SMALLINT)
RETURNS VOID AS $$
DECLARE
    a SMALLINT;
    m SMALLINT;
    siguiente_anio SMALLINT;
    siguiente_mes SMALLINT;
    d INT;
    dias_periodo INT;
    f_base DATE;
    fecha DATE;
    uf_anterior NUMERIC(12,4);
    uf_final NUMERIC(12,4);
    uf_interpolada NUMERIC(12,4);
    variacion_pct NUMERIC(6,3);
BEGIN
    -- Obtener UF base
    SELECT valor, fecha INTO uf_anterior, f_base FROM uf_base LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Debe existir una fila en uf_base';
    END IF;

    -- Borrar valores anteriores desde la fecha base
    DELETE FROM uf_diaria WHERE fecha >= f_base;

    -- Recalcular hacia adelante desde el mes inicial
    FOR a, m, variacion_pct IN
        SELECT anio, mes, variacion_mensual_pct
        FROM ipc_variacion_mensual
        WHERE (anio, mes) >= (inicio_anio, inicio_mes)
        ORDER BY anio, mes
    LOOP
        -- Calcular mes siguiente
        IF m = 12 THEN
            siguiente_anio := a + 1;
            siguiente_mes := 1;
        ELSE
            siguiente_anio := a;
            siguiente_mes := m + 1;
        END IF;

        -- Calcular fechas de inicio y fin del periodo
        fecha := make_date(a, m, 10);
        dias_periodo := (make_date(siguiente_anio, siguiente_mes, 9) - fecha) + 1;

        -- Calcular UF final redondeada
        uf_final := ROUND(uf_anterior * (1 + variacion_pct / 100), 2);

        -- Interpolación diaria
        FOR d IN 0..(dias_periodo - 1) LOOP
            INSERT INTO uf_diaria (fecha, valor)
            VALUES (
                fecha + d,
                ROUND(uf_anterior * (uf_final / uf_anterior) ^ (d::NUMERIC / dias_periodo), 2)
            );
        END LOOP;

        -- Actualizar UF para próximo ciclo
        uf_anterior := uf_final;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Trigger para prevenir huecos al eliminar
CREATE OR REPLACE FUNCTION evitar_eliminacion_consecutiva()
RETURNS TRIGGER AS $$
DECLARE
    siguiente RECORD;
BEGIN
    SELECT 1 INTO siguiente
    FROM ipc_variacion_mensual
    WHERE (anio > OLD.anio OR (anio = OLD.anio AND mes > OLD.mes))
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION 'No se puede eliminar la variación del mes %, %: existe una variación posterior que depende de ella.', OLD.anio, OLD.mes;
    END IF;

    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_evitar_huecos ON ipc_variacion_mensual;
CREATE TRIGGER trg_evitar_huecos
BEFORE DELETE ON ipc_variacion_mensual
FOR EACH ROW
EXECUTE FUNCTION evitar_eliminacion_consecutiva();

-- Trigger para recalcular UF automáticamente
CREATE OR REPLACE FUNCTION trigger_recalculo_ipc()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM recalcular_uf_desde(NEW.anio, NEW.mes);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_recalculo_ipc ON ipc_variacion_mensual;
CREATE TRIGGER trg_recalculo_ipc
AFTER INSERT OR UPDATE ON ipc_variacion_mensual
FOR EACH ROW
EXECUTE FUNCTION trigger_recalculo_ipc();
