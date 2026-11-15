begin;
create or replace function public.lab_admin_course_settings(p_class_id uuid,p_settings jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); cfg jsonb; peroxide double precision; iron double precision;
begin
  if not exists(select 1 from public.lab_classes where id=p_class_id and teacher_id=uid) then
    raise exception '講座が見つかりません。' using errcode='42501';end if;
  cfg:=jsonb_build_object('temp',25,'pressure',p_settings->'pressure','volume',p_settings->'volume',
    'unit',p_settings->'unit','input','total','mode',p_settings->'mode','c0',coalesce(p_settings->'c0','""'::jsonb),'wet',p_settings->'wet');
  if p_settings ? 'peroxide_volume' or p_settings ? 'iron_volume' then
    peroxide:=(p_settings->>'peroxide_volume')::double precision;
    iron:=(p_settings->>'iron_volume')::double precision;
    if peroxide is null or iron is null or not(peroxide>0 and peroxide<=10000 and iron>0 and iron<=10000 and peroxide+iron<=10000) then
      raise exception '各水溶液の体積を入力してください。合計は10,000 mL以下にしてください。';end if;
    cfg:=cfg||jsonb_build_object('peroxide_volume',peroxide,'iron_volume',iron,'volume',peroxide+iron);
  end if;
  perform public.lab_compute('[{"time":0,"vol":0}]',cfg);
  update public.lab_classes set settings=cfg where id=p_class_id and teacher_id=uid;
  return cfg;
end;
$$;
revoke all on function public.lab_admin_course_settings(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.lab_admin_course_settings(uuid,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
