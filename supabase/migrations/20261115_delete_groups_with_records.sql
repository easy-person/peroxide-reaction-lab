-- 教員が所有する班と、その班の提出記録をまとめて削除します。
begin;
create or replace function public.lab_admin_delete(p_group_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); target public.lab_groups; run_count bigint;
begin
  select * into target from public.lab_groups
    where id=p_group_id and teacher_id=uid for update;
  if not found then
    raise exception '班が見つかりません。' using errcode='42501';
  end if;
  select count(*) into run_count from public.lab_runs where group_id=target.id;
  -- lab_runs.group_id の ON DELETE CASCADE で同じ班の記録だけを削除します。
  delete from public.lab_groups where id=target.id;
  return jsonb_build_object('id',target.id,'label',target.label,'deleted',true,'deleted_runs',run_count);
end;
$$;
revoke all on function public.lab_admin_delete(uuid) from public,anon,authenticated;
grant execute on function public.lab_admin_delete(uuid) to authenticated;
commit;
