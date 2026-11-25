-- pgbench -n -c 8 -j 4 -T 20 -f tests/21_pgbench_contacto.sql <base>
\set n random(1, 100000)
begin;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select api.iniciar_contacto('whatsapp', '+5281' || lpad(:n::text, 8, '0'), 'ia', 'canal');
commit;
