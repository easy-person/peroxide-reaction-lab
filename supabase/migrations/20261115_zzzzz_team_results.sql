begin;
create index if not exists lab_runs_team_latest on public.lab_runs(group_id,team_label,created_at desc,id desc);
create or replace function public.lab_admin_team_result(p_group_id uuid,p_team_label text default null,p_run_id uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); g public.lab_groups; r public.lab_runs;
begin
  select * into g from public.lab_groups where id=p_group_id and teacher_id=uid;
  if not found then raise exception 'クラスが見つかりません。' using errcode='42501';end if;
  select * into r from public.lab_runs where group_id=g.id and
    ((p_run_id is not null and id=p_run_id) or (p_run_id is null and team_label is not distinct from p_team_label))
    order by created_at desc,id desc limit 1;
  if not found then raise exception 'この班の保存記録が見つかりません。一覧を更新してください。';end if;
  return jsonb_build_object('id',r.id,'team_label',r.team_label,'created_at',r.created_at,'rows',r.rows,'analysis',r.analysis,'settings',coalesce(r.settings,g.settings));
end;
$$;
revoke all on function public.lab_admin_team_result(uuid,text,uuid) from public,anon,authenticated;
grant execute on function public.lab_admin_team_result(uuid,text,uuid) to authenticated;
notify pgrst,'reload schema';
commit;
