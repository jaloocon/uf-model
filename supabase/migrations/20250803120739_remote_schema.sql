

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."calcular_uf_dia_9"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    prev_uf RECORD;
    ipc RECORD;
    nueva_uf NUMERIC(10,2);
    f9 DATE;
BEGIN
    -- Buscar la última UF registrada en el 9 de algún mes
    SELECT fecha, valor INTO prev_uf
    FROM uf_diaria
    WHERE EXTRACT(DAY FROM fecha) = 9
    ORDER BY fecha DESC
    LIMIT 1;

    -- Generar nuevas UF del día 9 a partir del último valor
    FOR ipc IN
        SELECT anio, mes, variacion
        FROM ipc_variacion_mensual
        WHERE (anio > EXTRACT(YEAR FROM prev_uf.fecha))
           OR (anio = EXTRACT(YEAR FROM prev_uf.fecha)
               AND mes > EXTRACT(MONTH FROM prev_uf.fecha))
        ORDER BY anio, mes
    LOOP
        f9 := TO_DATE(ipc.anio::text || '-' || ipc.mes::text || '-09', 'YYYY-MM-DD');
        nueva_uf := ROUND(prev_uf.valor * (1 + ipc.variacion / 100.0), 2);

        INSERT INTO uf_diaria (fecha, valor) VALUES (f9, nueva_uf);
        prev_uf.fecha := f9;
        prev_uf.valor := nueva_uf;
    END LOOP;
END;
$$;


ALTER FUNCTION "public"."calcular_uf_dia_9"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prohibir_delete_uf_base"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RAISE EXCEPTION 'Operación rechazada: El registro de la tabla uf_base no puede ser eliminado.';
END;
$$;


ALTER FUNCTION "public"."prohibir_delete_uf_base"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recalcular_uf_desde"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    uf_base_rec RECORD;
    fecha_inicio_periodo DATE;
    fecha_fin_periodo DATE;
    uf_inicio_periodo NUMERIC(14, 4);
    uf_fin_periodo NUMERIC(14, 4);
    ipc_variacion_periodo NUMERIC;
    dias_periodo INT;
    d INT;
    fecha_ipc DATE;
BEGIN
    -- 1. Obtener valor base.
    SELECT * INTO uf_base_rec FROM uf_base LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'uf_base está vacía.';
    END IF;

    -- 2. Limpieza completa y reinicio con el valor base.
    DELETE FROM uf_diaria;
    INSERT INTO uf_diaria (fecha, valor) VALUES (uf_base_rec.fecha, uf_base_rec.valor);

    -- 3. Inicializar variables para el bucle.
    fecha_inicio_periodo := uf_base_rec.fecha;
    uf_inicio_periodo := uf_base_rec.valor;

    -- 4. Bucle principal.
    LOOP
        -- a. Determinar la fecha del IPC requerido (mes anterior).
        fecha_ipc := (fecha_inicio_periodo - INTERVAL '1 month')::date;

        -- b. Obtener la variación de IPC para el período.
        SELECT variacion INTO ipc_variacion_periodo
        FROM ipc_variacion_mensual
        WHERE anio = EXTRACT(YEAR FROM fecha_ipc) AND mes = EXTRACT(MONTH FROM fecha_ipc);

        -- c. Si no hay más datos de IPC, terminar el bucle.
        IF NOT FOUND THEN
            EXIT;
        END IF;

        -- d. Calcular el valor de la UF para el fin del período.
        uf_fin_periodo := ROUND(uf_inicio_periodo * (1 + ipc_variacion_periodo / 100.0), 2);
        fecha_fin_periodo := (fecha_inicio_periodo + INTERVAL '1 month')::date;
        dias_periodo := fecha_fin_periodo - fecha_inicio_periodo;
        
        -- e. Interpolar e insertar los días del período.
        FOR d IN 1..dias_periodo LOOP
            INSERT INTO uf_diaria (fecha, valor)
            VALUES (
                fecha_inicio_periodo + d,
                ROUND(uf_inicio_periodo * (uf_fin_periodo / uf_inicio_periodo) ^ (d::NUMERIC / dias_periodo), 2)
            )
            ON CONFLICT (fecha) DO UPDATE SET valor = EXCLUDED.valor;
        END LOOP;
        
        -- f. Preparar la siguiente iteración.
        fecha_inicio_periodo := fecha_fin_periodo;
        uf_inicio_periodo := uf_fin_periodo;
    END LOOP;
END;
$$;


ALTER FUNCTION "public"."recalcular_uf_desde"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recalcular_uf_desde"("inicio_anio" integer, "inicio_mes" integer) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  uf_base_rec RECORD;
  ipc_rec RECORD;
  uf_anterior NUMERIC(12, 2);
  uf_siguiente_9 NUMERIC(12, 2);
  dias_periodo INT;
  d INT;
  fecha_actual_9 DATE;
BEGIN
  -- 1. Obtener el valor semilla inicial.
  SELECT * INTO uf_base_rec FROM uf_base LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se ha definido un valor inicial en la tabla uf_base.';
  END IF;

  -- 2. LIMPIEZA COMPLETA: Se usa DELETE FROM para mayor compatibilidad.
  DELETE FROM uf_diaria;
  INSERT INTO uf_diaria (fecha, valor) VALUES (uf_base_rec.fecha, uf_base_rec.valor);
  
  -- 3. Inicializar variables para el ciclo.
  uf_anterior := uf_base_rec.valor;
  fecha_actual_9 := uf_base_rec.fecha;

  -- 4. Iterar sobre las variaciones de IPC a partir del mes de la fecha base.
  FOR ipc_rec IN
    SELECT
      anio,
      mes,
      variacion
    FROM ipc_variacion_mensual
    WHERE make_date(anio, mes, 1) >= make_date(EXTRACT(YEAR FROM fecha_actual_9)::int, EXTRACT(MONTH FROM fecha_actual_9)::int, 1)
    ORDER BY anio, mes
  LOOP
    -- a. Calcular UF del día 9 del mes siguiente usando IPC del mes actual.
    uf_siguiente_9 := ROUND(uf_anterior * (1 + ipc_rec.variacion / 100.0), 2);
    
    -- b. Calcular días para la interpolación.
    dias_periodo := (fecha_actual_9 + INTERVAL '1 month')::date - fecha_actual_9;

    -- c. Interpolar los valores para el período.
    FOR d IN 1..dias_periodo LOOP
      INSERT INTO uf_diaria (fecha, valor)
      VALUES (
        fecha_actual_9 + (d || ' days')::interval,
        ROUND(uf_anterior * (CAST(uf_siguiente_9 AS NUMERIC) / uf_anterior) ^ (d::NUMERIC / dias_periodo), 2)
      )
      ON CONFLICT (fecha) DO UPDATE SET valor = EXCLUDED.valor;
    END LOOP;
    
    -- d. Actualizar variables para el siguiente ciclo.
    uf_anterior := uf_siguiente_9;
    fecha_actual_9 := (fecha_actual_9 + INTERVAL '1 month')::date;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."recalcular_uf_desde"("inicio_anio" integer, "inicio_mes" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trigger_prevenir_eliminacion_intermedia"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  existe_posterior BOOLEAN;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM ipc_variacion_mensual
    WHERE make_date(anio, mes, 1) > make_date(OLD.anio, OLD.mes, 1)
  ) INTO existe_posterior;

  IF existe_posterior THEN
    RAISE EXCEPTION 'No se puede eliminar la variación de IPC de %/%. Existen registros posteriores que dependen de ella.', OLD.mes, OLD.anio;
  END IF;

  -- Si se elimina el último, borra las UF generadas por él.
  DELETE FROM uf_diaria WHERE fecha >= make_date(OLD.anio, OLD.mes, 9);
  
  RETURN OLD;
END;
$$;


ALTER FUNCTION "public"."trigger_prevenir_eliminacion_intermedia"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trigger_recalcular_uf"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  PERFORM recalcular_uf_desde(NEW.anio, NEW.mes);
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trigger_recalcular_uf"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validar_fecha_ipc"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- a. Impedir la inserción de datos para meses futuros
    IF make_date(NEW.anio, NEW.mes, 1) > date_trunc('month', NOW()) THEN
        RAISE EXCEPTION 'No se puede insertar una variación de IPC para un mes futuro. Mes intentado: %/%', NEW.mes, NEW.anio;
    END IF;

    -- b. Garantizar la continuidad de la serie mensual
    IF NOT EXISTS (
        SELECT 1 FROM ipc_variacion_mensual
        WHERE make_date(anio, mes, 1) = make_date(NEW.anio, NEW.mes, 1) - INTERVAL '1 month'
    ) AND NOT EXISTS (
        -- Permitir la inserción del primer mes de la serie
        SELECT 1 FROM uf_base
        WHERE EXTRACT(YEAR FROM fecha) = NEW.anio AND EXTRACT(MONTH FROM fecha) = NEW.mes
    ) THEN
        RAISE EXCEPTION 'No se puede insertar la variación para el mes %/% porque falta la del mes anterior.', NEW.mes, NEW.anio;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."validar_fecha_ipc"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validar_uf_base_singleton"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Comprobar si ya existe alguna fila en la tabla.
    IF (SELECT COUNT(*) FROM uf_base) > 0 THEN
        RAISE EXCEPTION 'Operación rechazada: La tabla uf_base solo puede contener un único registro semilla.';
    END IF;

    -- Si la tabla está vacía, permitir la inserción.
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."validar_uf_base_singleton"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validar_update_uf_base"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Comprobar si la nueva fecha es posterior a la fecha del sistema.
    IF NEW.fecha > CURRENT_DATE THEN
        RAISE EXCEPTION 'Operación rechazada: La fecha base no puede ser una fecha futura. Fecha intentada: %', NEW.fecha;
    END IF;

    -- Permitir la actualización si la fecha es válida.
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."validar_update_uf_base"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."ipc_variacion_mensual" (
    "anio" smallint NOT NULL,
    "mes" smallint NOT NULL,
    "variacion" numeric(6,3) NOT NULL,
    CONSTRAINT "ipc_variacion_mensual_variacion_check" CHECK (("variacion" > ('-100'::integer)::numeric))
);


ALTER TABLE "public"."ipc_variacion_mensual" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."uf_base" (
    "fecha" "date" NOT NULL,
    "valor" numeric(10,2) NOT NULL
);


ALTER TABLE "public"."uf_base" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."uf_diaria" (
    "fecha" "date" NOT NULL,
    "valor" numeric(10,2) NOT NULL
);


ALTER TABLE "public"."uf_diaria" OWNER TO "postgres";


ALTER TABLE ONLY "public"."ipc_variacion_mensual"
    ADD CONSTRAINT "ipc_variacion_mensual_pkey" PRIMARY KEY ("anio", "mes");



ALTER TABLE ONLY "public"."uf_base"
    ADD CONSTRAINT "uf_base_pkey" PRIMARY KEY ("fecha");



ALTER TABLE ONLY "public"."uf_diaria"
    ADD CONSTRAINT "uf_diaria_pkey" PRIMARY KEY ("fecha");



CREATE OR REPLACE TRIGGER "trg_prevenir_eliminacion" BEFORE DELETE ON "public"."ipc_variacion_mensual" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_prevenir_eliminacion_intermedia"();



CREATE OR REPLACE TRIGGER "trg_prohibir_delete_uf_base" BEFORE DELETE ON "public"."uf_base" FOR EACH STATEMENT EXECUTE FUNCTION "public"."prohibir_delete_uf_base"();



CREATE OR REPLACE TRIGGER "trg_recalcular_uf" AFTER INSERT OR UPDATE ON "public"."ipc_variacion_mensual" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_recalcular_uf"();



CREATE OR REPLACE TRIGGER "trg_validar_fecha_ipc" BEFORE INSERT ON "public"."ipc_variacion_mensual" FOR EACH ROW EXECUTE FUNCTION "public"."validar_fecha_ipc"();



CREATE OR REPLACE TRIGGER "trg_validar_uf_base_singleton" BEFORE INSERT ON "public"."uf_base" FOR EACH STATEMENT EXECUTE FUNCTION "public"."validar_uf_base_singleton"();



CREATE OR REPLACE TRIGGER "trg_validar_update_uf_base" BEFORE UPDATE ON "public"."uf_base" FOR EACH ROW EXECUTE FUNCTION "public"."validar_update_uf_base"();





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";

























































































































































GRANT ALL ON FUNCTION "public"."calcular_uf_dia_9"() TO "anon";
GRANT ALL ON FUNCTION "public"."calcular_uf_dia_9"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."calcular_uf_dia_9"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prohibir_delete_uf_base"() TO "anon";
GRANT ALL ON FUNCTION "public"."prohibir_delete_uf_base"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prohibir_delete_uf_base"() TO "service_role";



GRANT ALL ON FUNCTION "public"."recalcular_uf_desde"() TO "anon";
GRANT ALL ON FUNCTION "public"."recalcular_uf_desde"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."recalcular_uf_desde"() TO "service_role";



GRANT ALL ON FUNCTION "public"."recalcular_uf_desde"("inicio_anio" integer, "inicio_mes" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."recalcular_uf_desde"("inicio_anio" integer, "inicio_mes" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."recalcular_uf_desde"("inicio_anio" integer, "inicio_mes" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."trigger_prevenir_eliminacion_intermedia"() TO "anon";
GRANT ALL ON FUNCTION "public"."trigger_prevenir_eliminacion_intermedia"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_prevenir_eliminacion_intermedia"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trigger_recalcular_uf"() TO "anon";
GRANT ALL ON FUNCTION "public"."trigger_recalcular_uf"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_recalcular_uf"() TO "service_role";



GRANT ALL ON FUNCTION "public"."validar_fecha_ipc"() TO "anon";
GRANT ALL ON FUNCTION "public"."validar_fecha_ipc"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."validar_fecha_ipc"() TO "service_role";



GRANT ALL ON FUNCTION "public"."validar_uf_base_singleton"() TO "anon";
GRANT ALL ON FUNCTION "public"."validar_uf_base_singleton"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."validar_uf_base_singleton"() TO "service_role";



GRANT ALL ON FUNCTION "public"."validar_update_uf_base"() TO "anon";
GRANT ALL ON FUNCTION "public"."validar_update_uf_base"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."validar_update_uf_base"() TO "service_role";


















GRANT ALL ON TABLE "public"."ipc_variacion_mensual" TO "anon";
GRANT ALL ON TABLE "public"."ipc_variacion_mensual" TO "authenticated";
GRANT ALL ON TABLE "public"."ipc_variacion_mensual" TO "service_role";



GRANT ALL ON TABLE "public"."uf_base" TO "anon";
GRANT ALL ON TABLE "public"."uf_base" TO "authenticated";
GRANT ALL ON TABLE "public"."uf_base" TO "service_role";



GRANT ALL ON TABLE "public"."uf_diaria" TO "anon";
GRANT ALL ON TABLE "public"."uf_diaria" TO "authenticated";
GRANT ALL ON TABLE "public"."uf_diaria" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";






























RESET ALL;
