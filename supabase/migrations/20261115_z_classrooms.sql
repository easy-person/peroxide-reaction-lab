begin;
create table if not exists public.lab_classes (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references public.lab_teachers(user_id),
  label text not null check(length(label) between 1 and 100),
  token_hash bytea not null unique,
  created_at timestamptz not null default now()
);
alter table public.lab_classes enable row level security;
revoke all on public.lab_classes from anon,authenticated;
alter table public.lab_groups add column if not exists class_id uuid references public.lab_classes(id) on delete set null;
alter table public.lab_groups add column if not exists code_hash bytea;
create unique index if not exists lab_group_class_label on public.lab_groups(class_id,label);
alter table public.lab_runs add column if not exists settings jsonb;
create table if not exists public.lab_group_sessions (
  token_hash bytea primary key,
  group_id uuid not null references public.lab_groups(id) on delete cascade,
  parent_hash bytea not null,
  expires_at timestamptz not null default now()+interval '24 hours'
);
alter table public.lab_group_sessions enable row level security;
revoke all on public.lab_group_sessions from anon,authenticated;

create or replace function public.lab_find_group(p_token text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare gid uuid;
begin
  if p_token is null or length(p_token)<>64 then raise exception '班のリンクが無効です。'; end if;
  select g.id into gid from public.lab_groups g where g.active and (
    g.token_hash=sha256(convert_to(p_token,'UTF8')) or exists(
      select 1 from public.lab_group_sessions s where s.group_id=g.id and s.parent_hash=g.token_hash
      and s.token_hash=sha256(convert_to(p_token,'UTF8')) and s.expires_at>now()));
  if gid is null then raise exception '班のリンクが無効、受付終了、または入室の有効期限切れです。クラスのリンクから入り直してください。'; end if;
  return gid;
end;
$$;
revoke all on function public.lab_find_group(text) from public,anon,authenticated;

create or replace function public.lab_class_open(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c public.lab_classes;
begin
  select * into c from public.lab_classes where token_hash=sha256(convert_to(p_token,'UTF8'));
  if not found then raise exception 'クラスのリンクが無効です。'; end if;
  return jsonb_build_object('label',c.label);
end;
$$;
create or replace function public.lab_class_join(p_token text,p_label text,p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare g public.lab_groups; t text;
begin
  select g1.* into g from public.lab_groups g1 join public.lab_classes c on c.id=g1.class_id
    where c.token_hash=sha256(convert_to(p_token,'UTF8')) and g1.active and g1.label=btrim(p_label)
    and g1.code_hash=sha256(convert_to(lower(replace(btrim(p_code),'-','')),'UTF8')) for update of g1;
  if not found then raise exception '班名・班別コードが一致しないか、受付が終了しています。'; end if;
  delete from public.lab_group_sessions where group_id=g.id and expires_at<=now();
  t:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');
  insert into public.lab_group_sessions(token_hash,group_id,parent_hash) values(sha256(convert_to(t,'UTF8')),g.id,g.token_hash);
  return jsonb_build_object('token',t,'label',g.label);
end;
$$;

create or replace function public.lab_student_open(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare g public.lab_groups; latest public.lab_runs;
begin
  select * into g from public.lab_groups where id=public.lab_find_group(p_token);
  select * into latest from public.lab_runs where group_id=g.id order by created_at desc,id desc limit 1;
  return jsonb_build_object('label',g.label,'settings',g.settings-'c0','record',case when latest.id is null then null else
    jsonb_build_object('id',latest.id,'created_at',latest.created_at,'rows',latest.rows,
      'temperature',(coalesce(latest.settings,g.settings)->>'temp')::double precision,
      'concentrations',latest.analysis->'concentrations','warning',latest.analysis->'warning') end);
end;
$$;
-- 古い画面の3引数呼び出しも既定温度で動作させます。
drop function if exists public.lab_student_save(text,jsonb,uuid);
create or replace function public.lab_student_save(p_token text,p_rows jsonb,p_request_id uuid,p_temperature double precision default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare g public.lab_groups; a jsonb; saved public.lab_runs; cfg jsonb; temp double precision;
begin
  select * into g from public.lab_groups where id=public.lab_find_group(p_token) for update;
  if not g.active then raise exception '受付を終了しています。'; end if;
  temp:=coalesce(p_temperature,(g.settings->>'temp')::double precision);
  if temp is null or not(temp between 0 and 60) then raise exception '測定温度を0～60 ℃で入力してください。'; end if;
  cfg:=g.settings||jsonb_build_object('temp',temp);
  select * into saved from public.lab_runs where group_id=g.id and request_id=p_request_id;
  if not found then
    if exists(select 1 from public.lab_runs where group_id=g.id and created_at>clock_timestamp()-interval '2 seconds') then
      raise exception '少し待ってから、もう一度保存してください。';
    end if;
    a:=public.lab_compute(p_rows,cfg);
    insert into public.lab_runs(group_id,request_id,rows,analysis,settings) values(g.id,p_request_id,p_rows,a,cfg) returning * into saved;
  end if;
  return jsonb_build_object('id',saved.id,'created_at',saved.created_at,'rows',saved.rows,
    'temperature',(coalesce(saved.settings,g.settings)->>'temp')::double precision,
    'concentrations',saved.analysis->'concentrations','warning',saved.analysis->'warning');
end;
$$;

create or replace function public.lab_admin_class_create(p_label text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); t text; cid uuid;
begin
  if p_label is null or length(btrim(p_label)) not between 1 and 100 then raise exception 'クラス名は1～100文字で入力してください。'; end if;
  t:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');
  insert into public.lab_classes(teacher_id,label,token_hash) values(uid,btrim(p_label),sha256(convert_to(t,'UTF8'))) returning id into cid;
  return jsonb_build_object('id',cid,'label',btrim(p_label),'token',t);
end;
$$;
create or replace function public.lab_admin_classes() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); result jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'label',c.label,'groups',(select count(*) from public.lab_groups where class_id=c.id)) order by c.created_at desc),'[]') into result from public.lab_classes c where teacher_id=uid;
  return result;
end;
$$;
create or replace function public.lab_admin_class_link(p_class_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); t text; name text;
begin
  t:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');
  update public.lab_classes set token_hash=sha256(convert_to(t,'UTF8')) where id=p_class_id and teacher_id=uid returning label into name;
  if not found then raise exception 'クラスが見つかりません。' using errcode='42501'; end if;
  return jsonb_build_object('label',name,'token',t);
end;
$$;
create or replace function public.lab_admin_assign(p_group_id uuid,p_class_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); code text; name text;
begin
  if not exists(select 1 from public.lab_classes where id=p_class_id and teacher_id=uid) then raise exception 'クラスが見つかりません。' using errcode='42501'; end if;
  code:=substr(replace(gen_random_uuid()::text,'-',''),1,12);
  update public.lab_groups set class_id=p_class_id,code_hash=sha256(convert_to(code,'UTF8')) where id=p_group_id and teacher_id=uid returning label into name;
  if not found then raise exception '班が見つかりません。' using errcode='42501'; end if;
  delete from public.lab_group_sessions where group_id=p_group_id;
  return jsonb_build_object('label',name,'code',code);
exception when unique_violation then raise exception '同じクラスに同じ班名があります。班名を変更してください。';
end;
$$;
drop function if exists public.lab_admin_create(text,jsonb);
create or replace function public.lab_admin_create(p_label text,p_settings jsonb,p_class_id uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); token text; gid uuid; code text;
begin
  if p_label is null or length(btrim(p_label)) not between 1 and 100 then raise exception '班名は1～100文字で入力してください。'; end if;
  if p_class_id is not null and not exists(select 1 from public.lab_classes where id=p_class_id and teacher_id=uid) then raise exception 'クラスが見つかりません。' using errcode='42501'; end if;
  perform public.lab_compute('[{"time":0,"vol":0}]',p_settings);
  token:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');
  if p_class_id is not null then code:=substr(replace(gen_random_uuid()::text,'-',''),1,12); end if;
  insert into public.lab_groups(teacher_id,label,token_hash,settings,class_id,code_hash)
    values(uid,btrim(p_label),sha256(convert_to(token,'UTF8')),p_settings,p_class_id,case when code is null then null else sha256(convert_to(code,'UTF8')) end) returning id into gid;
  return jsonb_build_object('id',gid,'label',btrim(p_label),'token',token,'code',code);
exception when unique_violation then raise exception '同じクラスに同じ班名があります。別の名前を入力してください。';
end;
$$;
create or replace function public.lab_admin_rename(p_group_id uuid,p_label text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); new_label text:=btrim(p_label); gid uuid;
begin
  if new_label is null or length(new_label) not between 1 and 100 then raise exception '班名は1～100文字で入力してください。'; end if;
  update public.lab_groups set label=new_label where id=p_group_id and teacher_id=uid returning id into gid;
  if not found then raise exception '班が見つかりません。' using errcode='42501'; end if;
  return jsonb_build_object('id',gid,'label',new_label);
exception when unique_violation then raise exception '同じクラスに同じ班名があります。';
end;
$$;
create or replace function public.lab_admin_groups() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); result jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'label',g.label,'class_id',g.class_id,'class_label',c.label,'active',g.active,'settings',g.settings,
    'created_at',g.created_at,'runs',(select count(*) from public.lab_runs where group_id=g.id),
    'latest',(select jsonb_build_object('id',r.id,'temperature',(coalesce(r.settings,g.settings)->>'temp')::double precision,
      'concentrations',r.analysis->'concentrations','k',r.analysis->'k','created_at',r.created_at) from public.lab_runs r where r.group_id=g.id order by r.created_at desc,r.id desc limit 1)) order by g.created_at desc),'[]') into result
    from public.lab_groups g left join public.lab_classes c on c.id=g.class_id where g.teacher_id=uid;
  return result;
end;
$$;
create or replace function public.lab_admin_runs(p_group_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); result jsonb; cfg jsonb;
begin
  select settings into cfg from public.lab_groups where id=p_group_id and teacher_id=uid;
  if not found then raise exception '班が見つかりません。' using errcode='42501'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'created_at',created_at,'rows',rows,'analysis',analysis,'settings',coalesce(settings,cfg)) order by created_at desc,id desc),'[]') into result
    from (select * from public.lab_runs where group_id=p_group_id order by created_at desc,id desc limit 100) r;
  return result;
end;
$$;
create or replace function public.lab_admin_delete_run(p_run_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); gid uuid;
begin
  select g.id into gid from public.lab_groups g join public.lab_runs r on r.group_id=g.id
    where r.id=p_run_id and g.teacher_id=uid for update of g;
  if not found then raise exception '記録が見つかりません。' using errcode='42501'; end if;
  delete from public.lab_runs where id=p_run_id and group_id=gid;
  return jsonb_build_object('deleted',true,'group_id',gid);
end;
$$;
revoke all on function public.lab_class_open(text),public.lab_class_join(text,text,text),public.lab_student_save(text,jsonb,uuid,double precision),public.lab_admin_class_create(text),public.lab_admin_classes(),public.lab_admin_class_link(uuid),public.lab_admin_assign(uuid,uuid),public.lab_admin_create(text,jsonb,uuid),public.lab_admin_delete_run(uuid) from public,anon,authenticated;
grant execute on function public.lab_class_open(text),public.lab_class_join(text,text,text),public.lab_student_save(text,jsonb,uuid,double precision) to anon;
grant execute on function public.lab_admin_class_create(text),public.lab_admin_classes(),public.lab_admin_class_link(uuid),public.lab_admin_assign(uuid,uuid),public.lab_admin_create(text,jsonb,uuid),public.lab_admin_delete_run(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
