begin;
alter table public.lab_classes add column if not exists settings jsonb;

create or replace function public.lab_admin_course_settings(p_class_id uuid,p_settings jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); cfg jsonb;
begin
  if not exists(select 1 from public.lab_classes where id=p_class_id and teacher_id=uid) then
    raise exception '講座が見つかりません。' using errcode='42501';end if;
  cfg:=jsonb_build_object('temp',25,'pressure',p_settings->'pressure','volume',p_settings->'volume',
    'unit',p_settings->'unit','input','total','mode',p_settings->'mode','c0',coalesce(p_settings->'c0','""'::jsonb),'wet',p_settings->'wet');
  perform public.lab_compute('[{"time":0,"vol":0}]',cfg);
  update public.lab_classes set settings=cfg where id=p_class_id and teacher_id=uid;
  return cfg;
end;
$$;
revoke all on function public.lab_admin_course_settings(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.lab_admin_course_settings(uuid,jsonb) to authenticated;

create or replace function public.lab_admin_classes() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); result jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'label',c.label,'groups',(select count(*) from public.lab_groups where class_id=c.id),
    'settings',coalesce(c.settings,(select g.settings from public.lab_groups g where g.class_id=c.id order by g.created_at,g.id limit 1),
      '{"temp":25,"pressure":101300,"volume":2,"unit":"min","input":"total","mode":"estimate","c0":"","wet":true}'::jsonb)) order by c.created_at desc),'[]') into result
    from public.lab_classes c where teacher_id=uid;
  return result;
end;
$$;

create or replace function public.lab_admin_create(p_label text,p_settings jsonb,p_class_id uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); token text; gid uuid; code text; cfg jsonb:=p_settings;
begin
  if p_label is null or length(btrim(p_label)) not between 1 and 100 then raise exception 'クラス名は1～100文字で入力してください。';end if;
  if p_class_id is not null then
    if not exists(select 1 from public.lab_classes where id=p_class_id and teacher_id=uid) then raise exception '講座が見つかりません。' using errcode='42501';end if;
    select coalesce(settings,p_settings) into cfg from public.lab_classes where id=p_class_id;
  end if;
  perform public.lab_compute('[{"time":0,"vol":0}]',cfg);
  token:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');
  if p_class_id is not null then code:=substr(replace(gen_random_uuid()::text,'-',''),1,12);end if;
  insert into public.lab_groups(teacher_id,label,token_hash,settings,class_id,code_hash)
    values(uid,btrim(p_label),sha256(convert_to(token,'UTF8')),cfg,p_class_id,case when code is null then null else sha256(convert_to(code,'UTF8')) end) returning id into gid;
  return jsonb_build_object('id',gid,'label',btrim(p_label),'token',token,'code',code);
exception when unique_violation then raise exception 'この講座には同じクラス名があります。';
end;
$$;

create or replace function public.lab_student_open(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare g public.lab_groups; latest public.lab_runs; own boolean; h bytea; cfg jsonb;
begin
  select * into g from public.lab_groups where id=public.lab_find_group(p_token);
  h:=sha256(convert_to(p_token,'UTF8'));select own_records into own from public.lab_group_sessions where token_hash=h;own:=coalesce(own,false);
  select coalesce(c.settings,g.settings) into cfg from public.lab_classes c where c.id=g.class_id;cfg:=coalesce(cfg,g.settings);
  if own then cfg:=cfg||jsonb_build_object('input','total');end if;
  select * into latest from public.lab_runs where group_id=g.id and (not own or session_hash=h) order by created_at desc,id desc limit 1;
  return jsonb_build_object('label',g.label,'settings',cfg-'c0','record',case when latest.id is null then null else
    jsonb_build_object('id',latest.id,'created_at',latest.created_at,'rows',latest.rows,'team_label',latest.team_label,'unit',coalesce(latest.settings,g.settings)->>'unit','input',coalesce(latest.settings,g.settings)->>'input',
      'temperature',(coalesce(latest.settings,g.settings)->>'temp')::double precision,
      'concentrations',latest.analysis->'concentrations','warning',latest.analysis->'warning') end);
end;
$$;

create or replace function public.lab_student_save(p_token text,p_rows jsonb,p_request_id uuid,p_temperature double precision default null,p_team_label text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare g public.lab_groups; a jsonb; saved public.lab_runs; cfg jsonb; temp double precision; h bytea; own boolean; team text:=btrim(p_team_label);
begin
  select * into g from public.lab_groups where id=public.lab_find_group(p_token) for update;
  if not g.active then raise exception '受付を終了しています。';end if;
  h:=sha256(convert_to(p_token,'UTF8'));select own_records into own from public.lab_group_sessions where token_hash=h;own:=coalesce(own,false);
  if own and (team is null or length(team) not between 1 and 100) then raise exception '班名を1～100文字で入力してください。';end if;
  if team is not null and length(team) not between 1 and 100 then raise exception '班名を1～100文字で入力してください。';end if;
  temp:=coalesce(p_temperature,(g.settings->>'temp')::double precision);
  if temp is null or not(temp between 0 and 60) then raise exception '実験温度を0～60 ℃で入力してください。';end if;
  select coalesce(c.settings,g.settings) into cfg from public.lab_classes c where c.id=g.class_id;cfg:=coalesce(cfg,g.settings)||jsonb_build_object('temp',temp);
  if own then cfg:=cfg||jsonb_build_object('input','total');end if;
  select * into saved from public.lab_runs where group_id=g.id and request_id=p_request_id;
  if found and own and saved.session_hash is distinct from h then raise exception '保存要求が無効です。';end if;
  if not found then
    if exists(select 1 from public.lab_runs where group_id=g.id and (not own or session_hash=h) and created_at>clock_timestamp()-interval '2 seconds') then
      raise exception '少し待ってから、もう一度保存してください。';end if;
    a:=public.lab_compute(p_rows,cfg);
    insert into public.lab_runs(group_id,request_id,rows,analysis,settings,team_label,session_hash)
      values(g.id,p_request_id,p_rows,a,cfg,team,case when own then h else null end) returning * into saved;
  end if;
  return jsonb_build_object('id',saved.id,'created_at',saved.created_at,'rows',saved.rows,'team_label',saved.team_label,
    'temperature',(coalesce(saved.settings,g.settings)->>'temp')::double precision,
    'concentrations',saved.analysis->'concentrations','warning',saved.analysis->'warning');
end;
$$;
create or replace function public.lab_admin_course_rename(p_class_id uuid,p_label text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); name text:=btrim(p_label); cid uuid;
begin
  if name is null or length(name) not between 1 and 100 then raise exception '講座名は1～100文字で入力してください。';end if;
  update public.lab_classes set label=name where id=p_class_id and teacher_id=uid returning id into cid;
  if not found then raise exception '講座が見つかりません。' using errcode='42501';end if;
  return jsonb_build_object('id',cid,'label',name);
end;
$$;
create or replace function public.lab_admin_course_delete(p_class_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); target public.lab_classes; group_count bigint; run_count bigint;
begin
  select * into target from public.lab_classes where id=p_class_id and teacher_id=uid for update;
  if not found then raise exception '講座が見つかりません。' using errcode='42501';end if;
  if exists(select 1 from public.lab_groups where class_id=target.id and teacher_id<>uid) then raise exception 'この講座には他の教員のクラスが含まれるため削除できません。' using errcode='42501';end if;
  perform 1 from public.lab_groups where class_id=target.id for update;
  select count(*) into group_count from public.lab_groups where class_id=target.id;
  select count(*) into run_count from public.lab_runs r join public.lab_groups g on g.id=r.group_id where g.class_id=target.id;
  delete from public.lab_groups where class_id=target.id and teacher_id=uid;
  delete from public.lab_classes where id=target.id and teacher_id=uid;
  return jsonb_build_object('deleted',true,'label',target.label,'deleted_classes',group_count,'deleted_runs',run_count);
end;
$$;
revoke all on function public.lab_admin_course_rename(uuid,text),public.lab_admin_course_delete(uuid) from public,anon,authenticated;
grant execute on function public.lab_admin_course_rename(uuid,text),public.lab_admin_course_delete(uuid) to authenticated;

notify pgrst,'reload schema';
commit;
