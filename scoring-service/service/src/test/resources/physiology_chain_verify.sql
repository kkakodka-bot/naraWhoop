do $$ declare r record; j jsonb; begin
  for r in select * from audit_fixture.before_rows loop
    execute format('select jsonb_agg(to_jsonb(r) order by to_jsonb(r)::text) from public.%I r',r.table_name) into j;
    assert j=r.rows,'source rows changed: '||r.table_name;
  end loop;
  assert (select count(*)=3 from noop_rr_intervals),'same-second RR lost';
  assert (select attempts=0 and done_at is null and input_revision>0 from scoring_work_items where day='2026-09-17'),'old work reset missing';
  assert exists(select 1 from scoring_work_items where day='2026-09-16') and
    (select input_revision>1 from scoring_work_items where day='2026-09-17'),'event-day and following-day catchup missing';
  assert not exists(select 1 from physiology_source_selection where algorithm_version<>'frwhoop-server-1');
end $$;
