-- 保存記録がない班だけを、その班の教員が削除できます。
begin;
create or replace function public.lab_admin_delete(p_group_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); target public.lab_groups;
begin
  select * into target from public.lab_groups
    where id=p_group_id and teacher_id=uid for update;
  if not found then
    raise exception '班が見つかりません。' using errcode='42501';
  end if;
  if exists(select 1 from public.lab_runs where group_id=target.id) then
    raise exception '保存記録がある班は削除できません。リンクを無効にする場合は「班専用リンクを削除」を使ってください。';
  end if;
  delete from public.lab_groups where id=target.id;
  return jsonb_build_object('id',target.id,'label',target.label,'deleted',true);
end;
$$;
revoke all on function public.lab_admin_delete(uuid) from public,anon,authenticated;
grant execute on function public.lab_admin_delete(uuid) to authenticated;
commit;
