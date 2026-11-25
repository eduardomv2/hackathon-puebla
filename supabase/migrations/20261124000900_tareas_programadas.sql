-- =====================================================================
-- 0900 · Tareas programadas (pg_cron)
-- =====================================================================

-- Resumen casi en tiempo real: revisa la cola cada 5 s; solo invoca la Edge Function si hay trabajo
select cron.schedule('sd-resumenes',     '5 seconds',   $$select core.despachar_worker('resumen_tramite', 'procesar-resumenes')$$);
select cron.schedule('sd-recordatorios', '30 seconds',  $$select core.despachar_worker('recordatorios', 'enviar-recordatorios')$$);

select cron.schedule('sd-programar-recordatorios', '*/5 * * * *', $$select core.programar_recordatorios()$$);
select cron.schedule('sd-expirar',                 '*/5 * * * *', $$select core.expirar_tramites()$$);
select cron.schedule('sd-cerrar-sesiones',         '*/5 * * * *', $$select core.cerrar_interacciones_inactivas()$$);
select cron.schedule('sd-metricas',                '*/5 * * * *', $$select core.refrescar_metricas()$$);
select cron.schedule('sd-limpieza',                '17 * * * *',  $$select core.limpieza()$$);

-- Particiones: a diario asegura las de los próximos 3 meses
select cron.schedule('sd-particiones', '7 3 * * *', $$
  select core.asegurar_particiones('core.eventos_tramite');
  select core.asegurar_particiones('core.mensajes');
  select core.asegurar_particiones('audit.registro');
$$);
