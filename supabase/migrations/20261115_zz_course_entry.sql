begin;
alter table public.lab_group_sessions add column if not exists own_records boolean not null default false;
alter table public.lab_runs add column if not exists team_label text check(team_label is null or length(team_label) between 1 and 100);
alter table public.lab_runs add column if not exists session_hash bytea;
create index if not exists lab_runs_session on public.lab_runs(group_id,session_hash,created_at desc);

create or replace function public.lab_course_open(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c public.lab_classes; options jsonb;
begin
  select * into c from public.lab_classes where token_hash=sha256(convert_to(p_token,'UTF8'));
  if not found then raise exception '講座リンクが無効です。'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'label',g.label) order by g.created_at,g.id),'[]') into options
    from public.lab_groups g where g.class_id=c.id and g.active;
  return jsonb_build_object('label',c.label,'classes',options);
end;
$$;
create or replace function public.lab_course_enter(p_token text,p_group_id uuid,p_device_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare g public.lab_groups; h bytea;
begin
  if p_device_token is null or p_device_token !~ '^[a-f0-9]{64}$' then raise exception '入力画面を開き直してください。'; end if;
  select g1.* into g from public.lab_groups g1 join public.lab_classes c on c.id=g1.class_id
    where c.token_hash=sha256(convert_to(p_token,'UTF8')) and g1.id=p_group_id and g1.active for update of g1;
  if not found then raise exception 'このクラスは受付終了、またはこの講座に所属していません。'; end if;
  h:=sha256(convert_to(p_device_token,'UTF8'));
  if exists(select 1 from public.lab_group_sessions where token_hash=h and (group_id<>g.id or not own_records)) then
    raise exception '入力画面を開き直してください。';
  end if;
  insert into public.lab_group_sessions(token_hash,group_id,parent_hash,own_records,expires_at)
    values(h,g.id,g.token_hash,true,now()+interval '24 hours')
    on conflict(token_hash) do update set parent_hash=excluded.parent_hash,expires_at=excluded.expires_at;
  return jsonb_build_object('label',g.label);
end;
$$;

create or replace function public.lab_student_open(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare g public.lab_groups; latest public.lab_runs; own boolean; h bytea; cfg jsonb;
begin
  select * into g from public.lab_groups where id=public.lab_find_group(p_token);
  h:=sha256(convert_to(p_token,'UTF8'));
  select own_records into own from public.lab_group_sessions where token_hash=h;
  own:=coalesce(own,false);cfg:=g.settings;
  if own then cfg:=cfg||jsonb_build_object('input','total');end if;
  select * into latest from public.lab_runs where group_id=g.id and (not own or session_hash=h) order by created_at desc,id desc limit 1;
  return jsonb_build_object('label',g.label,'settings',cfg-'c0','record',case when latest.id is null then null else
    jsonb_build_object('id',latest.id,'created_at',latest.created_at,'rows',latest.rows,'team_label',latest.team_label,
      'temperature',(coalesce(latest.settings,g.settings)->>'temp')::double precision,
      'concentrations',latest.analysis->'concentrations','warning',latest.analysis->'warning') end);
end;
$$;

drop function if exists public.lab_student_save(text,jsonb,uuid,double precision);
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
  cfg:=g.settings||jsonb_build_object('temp',temp);
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

create or replace function public.lab_admin_runs(p_group_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); result jsonb; cfg jsonb;
begin
  select settings into cfg from public.lab_groups where id=p_group_id and teacher_id=uid;
  if not found then raise exception 'クラスが見つかりません。' using errcode='42501';end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'team_label',team_label,'created_at',created_at,'rows',rows,'analysis',analysis,'settings',coalesce(settings,cfg)) order by created_at desc,id desc),'[]') into result
    from (select * from public.lab_runs where group_id=p_group_id order by created_at desc,id desc limit 100) r;
  return result;
end;
$$;
create or replace function public.lab_admin_groups() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); result jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'label',g.label,'class_id',g.class_id,'class_label',c.label,'active',g.active,'settings',g.settings,
    'created_at',g.created_at,'runs',(select count(*) from public.lab_runs where group_id=g.id),
    'latest',(select jsonb_build_object('id',r.id,'team_label',r.team_label,'temperature',(coalesce(r.settings,g.settings)->>'temp')::double precision,
      'concentrations',r.analysis->'concentrations','k',r.analysis->'k','created_at',r.created_at) from public.lab_runs r where r.group_id=g.id order by r.created_at desc,r.id desc limit 1),
    'teams',(select coalesce(jsonb_agg(jsonb_build_object('team_label',t.team_label,'temperature',(coalesce(t.settings,g.settings)->>'temp')::double precision,
      'concentrations',t.analysis->'concentrations','k',t.analysis->'k','created_at',t.created_at)),'[]') from
      (select distinct on (team_label) * from public.lab_runs where group_id=g.id order by team_label,created_at desc,id desc) t)) order by g.created_at desc),'[]') into result
    from public.lab_groups g left join public.lab_classes c on c.id=g.class_id where g.teacher_id=uid;
  return result;
end;
$$;
revoke all on function public.lab_course_open(text),public.lab_course_enter(text,uuid,text),public.lab_student_save(text,jsonb,uuid,double precision,text) from public,anon,authenticated;
grant execute on function public.lab_course_open(text),public.lab_course_enter(text,uuid,text),public.lab_student_save(text,jsonb,uuid,double precision,text) to anon;
notify pgrst,'reload schema';
commit;
