-- Optional provenance for the actual PPG contributor selection; old rows remain unspecified.
-- Preserve 070 and its installed constraints/privileges. Neither physiological algorithm changes.
create or replace function public.noop_valid_scalar_provenance(p jsonb) returns boolean
language plpgsql immutable set search_path=pg_catalog,public as $$
declare k text; v jsonb; n numeric;
begin
  if p is null then return true; end if;
  if jsonb_typeof(p) is distinct from 'object' or octet_length(p::text)>1024
    or p->'v' is distinct from '1'::jsonb
    or coalesce(p->>'origin','') not in ('whoop-v18','whoop-v26-ppg-derived','legacy-unknown') then return false; end if;
  for k,v in select * from jsonb_each(p) loop
    if k not in ('v','origin','recordIndex','frameSHA256','algorithm','sampleRateHz',
      'windowSettingSeconds','inputStartTs','inputEndTs','inputSHA256','inputSelection')
      or jsonb_typeof(v) not in ('string','number') then return false; end if;
    if k in ('recordIndex','sampleRateHz','windowSettingSeconds','inputStartTs','inputEndTs') then
      if jsonb_typeof(v)<>'number' then return false; end if;
      n:=(v::text)::numeric;
      if n<>trunc(n) or abs(n)>9007199254740991 then return false; end if;
      if k='recordIndex' and (n<0 or n>4294967295) then return false; end if;
      if k in ('sampleRateHz','windowSettingSeconds') and n<=0 then return false; end if;
    end if;
    if k in ('frameSHA256','inputSHA256') and (jsonb_typeof(v)<>'string' or (v#>>'{}') !~ '^[0-9a-f]{64}$') then return false; end if;
    if k='algorithm' and (v#>>'{}') not in ('ppg-acf-v1','ppg-acf-sublag-v1') then return false; end if;
    if k='inputSelection' and (jsonb_typeof(v)<>'string' or
      (v#>>'{}') not in ('last-record-per-second-v1','concat-records-per-second-v1')) then return false; end if;
  end loop;
  if p ? 'inputStartTs' and p ? 'inputEndTs' and (p->>'inputEndTs')::numeric<=(p->>'inputStartTs')::numeric then return false; end if;
  if p->>'origin'='whoop-v26-ppg-derived' then
    if p ?| array['recordIndex','frameSHA256'] or not (p ?& array['algorithm','sampleRateHz','windowSettingSeconds','inputStartTs','inputEndTs','inputSHA256']) then return false; end if;
  else
    if p ?| array['algorithm','sampleRateHz','windowSettingSeconds','inputStartTs','inputEndTs','inputSHA256','inputSelection'] then return false; end if;
    if p->>'origin'='legacy-unknown' and p ?| array['recordIndex','frameSHA256'] then return false; end if;
  end if;
  return true;
end $$;
revoke all on function public.noop_valid_scalar_provenance(jsonb) from public,anon,authenticated;
grant execute on function public.noop_valid_scalar_provenance(jsonb) to service_role;
