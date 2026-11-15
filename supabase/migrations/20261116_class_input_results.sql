begin;
create or replace function public.lab_student_class_inputs(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare g public.lab_groups; result jsonb;
begin
  select * into g from public.lab_groups where id=public.lab_find_group(p_token);
  select coalesce(jsonb_agg(jsonb_build_object(
    'team_label',r.team_label,'created_at',r.created_at,
    'temperature',(coalesce(r.settings,g.settings)->>'temp')::double precision,
    'unit',coalesce(r.settings,g.settings)->>'unit','input',coalesce(r.settings,g.settings)->>'input',
    'rows',(select coalesce(jsonb_agg(jsonb_build_object('time',v.value->'time','vol',v.value->'vol') order by v.position),'[]')
      from jsonb_array_elements(r.rows) with ordinality v(value,position)))
    order by r.team_label nulls last),'[]') into result
    from (select distinct on (team_label) team_label,created_at,settings,rows,id from public.lab_runs
      where group_id=g.id order by team_label,created_at desc,id desc) r;
  return jsonb_build_object('label',g.label,'records',result);
end;
$$;
revoke all on function public.lab_student_class_inputs(text) from public,anon,authenticated;
grant execute on function public.lab_student_class_inputs(text) to anon;
notify pgrst,'reload schema';
commit;
