-- 班名だけを変更します。ID・トークン・実験条件・提出記録は変更しません。
begin;
create or replace function public.lab_admin_rename(p_group_id uuid,p_label text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); new_label text:=btrim(p_label); target_id uuid;
begin
  if new_label is null or length(new_label) not between 1 and 100 then
    raise exception '班名は1～100文字で入力してください。';
  end if;
  update public.lab_groups set label=new_label
    where id=p_group_id and teacher_id=uid returning id into target_id;
  if not found then
    raise exception '班が見つかりません。' using errcode='42501';
  end if;
  return jsonb_build_object('id',target_id,'label',new_label);
end;
$$;
revoke all on function public.lab_admin_rename(uuid,text) from public,anon,authenticated;
grant execute on function public.lab_admin_rename(uuid,text) to authenticated;
commit;
