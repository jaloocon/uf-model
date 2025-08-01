
# Modelo UF – Supabase + GitHub

Este proyecto contiene un modelo determinista y auditable para calcular la UF diaria chilena desde un valor base y una serie de variaciones mensuales del IPC.

## Estructura del proyecto

- `schema/modelo_uf.sql`: define todas las tablas, funciones y triggers necesarios
- `data/uf_base.csv`: contiene el valor inicial de la UF
- `data/ipc_variacion_mensual.csv`: contiene las variaciones mensuales del IPC como porcentaje
- `scripts/`: carpeta vacía para futuros scripts automáticos

## Flujo recomendado paso a paso

1. Crear el proyecto en Supabase desde https://supabase.com
2. Subir el contenido de `modelo_uf.sql` al SQL Editor y ejecutarlo
3. Cargar los CSV desde Table Editor en las tablas correspondientes
4. Verificar la generación automática de `uf_diaria`
5. Regenerar UF manualmente con: `SELECT recalcular_uf_desde(2022, 1);`
