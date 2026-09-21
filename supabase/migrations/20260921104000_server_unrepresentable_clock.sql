-- Sensor clocks that PostgreSQL cannot represent must remain durable without inventing
-- a measurement day. The physiology queue already abstains; align the historical trigger
-- reader so its timestamp conversion cannot abort the entire intake transaction.
create or replace function public.scoring_local_day_v2(p_time text,p_zone text) returns date
language plpgsql stable set search_path=pg_catalog,public as $$
declare observed timestamptz;
begin
  observed:=case when p_time ~ '^-?[0-9]+(\.[0-9]+)?$' then to_timestamp(p_time::double precision)
    else p_time::timestamptz end;
  if observed is null or not isfinite(observed) then return null; end if;
  return (observed at time zone coalesce((select name from pg_timezone_names where name=p_zone),'UTC'))::date;
exception when datetime_field_overflow or numeric_value_out_of_range or invalid_datetime_format
  or invalid_text_representation then
  return null;
end $$;
