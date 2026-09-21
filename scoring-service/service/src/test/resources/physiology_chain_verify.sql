do $$ declare r record; j jsonb; begin
  for r in select * from audit_fixture.before_rows loop
    if r.table_name='noop_gravity_samples' then
      select jsonb_agg(to_jsonb(g)-array['motion_evidence_version','orientation_evidence_version'] order by to_jsonb(g)::text)
        into j from noop_gravity_samples g;
      assert not exists(select 1 from noop_gravity_samples where motion_evidence_version is not null or orientation_evidence_version is not null),
        'historical numeric values cannot gain acquisition proof';
    else
      execute format('select jsonb_agg(to_jsonb(r) order by to_jsonb(r)::text) from public.%I r',r.table_name) into j;
    end if;
    assert j=r.rows,'source rows changed: '||r.table_name;
  end loop;
  assert (select count(*)=3 from noop_rr_intervals),'same-second RR lost';
  assert (select attempts=0 and done_at is null and input_revision>0 from scoring_work_items where day='2026-09-17'),'old work reset missing';
  assert exists(select 1 from scoring_work_items where day='2026-09-16') and
    (select input_revision>1 from scoring_work_items where day='2026-09-17'),'event-day and following-day catchup missing';
  assert not exists(select 1 from physiology_source_selection where algorithm_version<>'frwhoop-server-1');
  assert (select count(*)=1 and min(counter)=321 and min("activityClass")=2 and min(activity_class)=2
    from noop_step_samples),'step schema merge changed historical measurements';
end $$;
