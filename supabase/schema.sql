-- Supabase SQL Editorで1回実行します。公開APIは末尾のRPCのみです。
create table public.lab_teachers (
  user_id uuid primary key references auth.users(id) on delete cascade
);
create table public.lab_groups (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references public.lab_teachers(user_id),
  label text not null check(length(label) between 1 and 100),
  token_hash bytea not null unique,
  settings jsonb not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create table public.lab_runs (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.lab_groups(id) on delete cascade,
  request_id uuid not null,
  rows jsonb not null,
  analysis jsonb not null,
  created_at timestamptz not null default now(),
  unique(group_id, request_id)
);
create index lab_runs_group_created on public.lab_runs(group_id,created_at desc);
alter table public.lab_teachers enable row level security;
alter table public.lab_groups enable row level security;
alter table public.lab_runs enable row level security;
revoke all on public.lab_teachers, public.lab_groups, public.lab_runs from anon, authenticated;

create function public.lab_compute(p_rows jsonb, p_settings jsonb) returns jsonb
language plpgsql set search_path = '' as $$
declare
  r jsonb; t double precision; v double precision; temp double precision;
  pressure double precision; liquid double precision; oxygen_p double precision;
  factor double precision; prev_t double precision:=0; prev_v double precision:=0;
  base_v double precision:=0; total double precision:=0; d double precision:=0; prev_d double precision:=0;
  x double precision; y double precision; sx double precision:=0; sy double precision:=0;
  sxx double precision:=0; sxy double precision:=0; count_points integer:=0;
  k double precision; intercept double precision; c0 double precision;
  intermediates jsonb:='[]'; concentrations jsonb:='[]'; rates jsonb:='[]'; warning text:='';
  i integer:=0;
begin
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) not between 1 and 101 then
    raise exception '初期行を含めて1～101行で入力してください。';
  end if;
  temp:=(p_settings->>'temp')::double precision; pressure:=(p_settings->>'pressure')::double precision;
  liquid:=(p_settings->>'volume')::double precision;
  if temp is null or not(temp between 0 and 60) or pressure is null or not(pressure between 10000 and 200000)
     or liquid is null or not(liquid between 0.001 and 10000)
     or coalesce(p_settings->>'unit','') not in ('min','s')
     or coalesce(p_settings->>'input','') not in ('total','interval')
     or coalesce(p_settings->>'mode','') not in ('known','estimate')
     or jsonb_typeof(p_settings->'wet') is distinct from 'boolean' then
    raise exception '実験条件が不正です。';
  end if;
  oxygen_p:=pressure;
  if (p_settings->>'wet')::boolean then
    oxygen_p:=pressure-power(10::double precision,8.02754-1705.616/(231.405+temp))/760*101300;
  end if;
  if oxygen_p<=0 then raise exception '酸素の分圧が0以下です。'; end if;
  factor:=oxygen_p*0.000001/(8.31*(temp+273.15));
  for r in select value from jsonb_array_elements(p_rows) loop
    if jsonb_typeof(r) is distinct from 'object' or coalesce(r->>'time','')='' or coalesce(r->>'vol','')='' then
      raise exception '時間・体積をすべて入力してください。';
    end if;
    t:=(r->>'time')::double precision; v:=(r->>'vol')::double precision;
    if p_settings->>'unit'='min' then t:=t*60; end if;
    if not(t between 0 and 86400) or not(v between 0 and 100000) then raise exception '時間・体積が範囲外です。'; end if;
    if i=0 then
      if t<>0 then raise exception '最初の行は0分にしてください。'; end if;
      base_v:=v; prev_v:=v;
      intermediates:=intermediates||jsonb_build_array(jsonb_build_object('t',0,'d',0));
    else
      if t<=prev_t then raise exception '時間は前回より大きくしてください。'; end if;
      if p_settings->>'input'='total' then
        if v<prev_v then raise exception '累積体積は前回以上にしてください。'; end if;
        total:=v-base_v;
      else total:=total+v;
      end if;
      d:=2*factor*total/(liquid/1000);
      x:=-(d+prev_d)/2; y:=(d-prev_d)/(t-prev_t);
      sx:=sx+x;sy:=sy+y;sxx:=sxx+x*x;sxy:=sxy+x*y;count_points:=count_points+1;
      intermediates:=intermediates||jsonb_build_array(jsonb_build_object('t',t,'d',d));
      rates:=rates||jsonb_build_array(jsonb_build_object('x',x,'rate',y));
      prev_d:=d;
    end if;
    prev_t:=t; prev_v:=v; i:=i+1;
  end loop;
  if count_points>=3 and abs(sxx-sx*sx/count_points)>1e-20 then
    k:=(sxy-sx*sy/count_points)/(sxx-sx*sx/count_points);
    intercept:=(sy-k*sx)/count_points;
  end if;
  if p_settings->>'mode'='known' then
    c0:=(p_settings->>'c0')::double precision;
    if c0 is null or not(c0>0 and c0<100) then raise exception '初濃度を正しく設定してください。'; end if;
  elsif k>0 and intercept/k>0 then c0:=intercept/k;
  else warning:='初濃度を推定できません。3区間以上の測定と、時間とともに低下する速度が必要です。';
  end if;
  for r in select value from jsonb_array_elements(intermediates) loop
    if c0-(r->>'d')::double precision<0 then warning:='負の濃度が計算されました。教員に実験条件と記録を確認してもらってください。'; end if;
    concentrations:=concentrations||jsonb_build_array(jsonb_build_object('t',r->'t','c',c0-(r->>'d')::double precision));
  end loop;
  return jsonb_build_object('concentrations',concentrations,'rates',rates,'c0',c0,'k',k,'intercept',intercept,'warning',warning);
end;
$$;
revoke all on function public.lab_compute(jsonb,jsonb) from public, anon, authenticated;

create function public.lab_require_teacher() returns uuid
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=auth.uid();
begin
  if uid is null or not exists(select 1 from public.lab_teachers where user_id=uid) then
    raise exception '管理者の認証が必要です。' using errcode='42501';
  end if;
  return uid;
end;
$$;
revoke all on function public.lab_require_teacher() from public, anon, authenticated;

create function public.lab_student_open(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare g public.lab_groups; latest public.lab_runs;
begin
  if p_token is null or length(p_token)<>64 then raise exception '班のリンクが無効です。'; end if;
  select * into g from public.lab_groups where token_hash=sha256(convert_to(p_token,'UTF8')) and active;
  if not found then raise exception '班のリンクが無効、または受付を終了しています。'; end if;
  select * into latest from public.lab_runs where group_id=g.id order by created_at desc,id desc limit 1;
  return jsonb_build_object('label',g.label,'settings',g.settings-'c0','record',case when latest.id is null then null else
    jsonb_build_object('id',latest.id,'created_at',latest.created_at,'rows',latest.rows,
      'concentrations',latest.analysis->'concentrations','warning',latest.analysis->'warning') end);
end;
$$;

create function public.lab_student_save(p_token text,p_rows jsonb,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare g public.lab_groups; a jsonb; saved public.lab_runs;
begin
  if p_token is null or length(p_token)<>64 then raise exception '班のリンクが無効です。'; end if;
  select * into g from public.lab_groups where token_hash=sha256(convert_to(p_token,'UTF8')) and active for update;
  if not found then raise exception '班のリンクが無効、または受付を終了しています。'; end if;
  select * into saved from public.lab_runs where group_id=g.id and request_id=p_request_id;
  if not found then
    if exists(select 1 from public.lab_runs where group_id=g.id and created_at>clock_timestamp()-interval '2 seconds') then
      raise exception '少し待ってから、もう一度保存してください。';
    end if;
    a:=public.lab_compute(p_rows,g.settings);
    insert into public.lab_runs(group_id,request_id,rows,analysis) values(g.id,p_request_id,p_rows,a) returning * into saved;
  end if;
  return jsonb_build_object('id',saved.id,'created_at',saved.created_at,'rows',saved.rows,
    'concentrations',saved.analysis->'concentrations','warning',saved.analysis->'warning');
end;
$$;

create function public.lab_admin_create(p_label text,p_settings jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); token text; gid uuid;
begin
  if p_label is null or length(trim(p_label)) not between 1 and 100 then raise exception '班の名前を入力してください。'; end if;
  perform public.lab_compute('[{"time":0,"vol":0}]',p_settings);
  token:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');
  insert into public.lab_groups(teacher_id,label,token_hash,settings)
    values(uid,trim(p_label),sha256(convert_to(token,'UTF8')),p_settings) returning id into gid;
  return jsonb_build_object('id',gid,'label',trim(p_label),'token',token);
end;
$$;

create function public.lab_admin_groups() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); result jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'label',g.label,'active',g.active,'settings',g.settings,
    'created_at',g.created_at,'runs',(select count(*) from public.lab_runs where group_id=g.id)) order by g.created_at desc),'[]') into result
    from public.lab_groups g where g.teacher_id=uid;
  return result;
end;
$$;

create function public.lab_admin_runs(p_group_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); result jsonb;
begin
  if not exists(select 1 from public.lab_groups where id=p_group_id and teacher_id=uid) then raise exception '班が見つかりません。' using errcode='42501'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'created_at',created_at,'rows',rows,'analysis',analysis) order by created_at desc,id desc),'[]') into result
    from (select * from public.lab_runs where group_id=p_group_id order by created_at desc,id desc limit 100) r;
  return result;
end;
$$;

create function public.lab_admin_access(p_group_id uuid,p_active boolean,p_rotate boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); token text;
begin
  if p_active is null then raise exception '受付状態を指定してください。'; end if;
  if p_rotate then token:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-',''); end if;
  update public.lab_groups set active=p_active,token_hash=case when p_rotate then sha256(convert_to(token,'UTF8')) else token_hash end
    where id=p_group_id and teacher_id=uid;
  if not found then raise exception '班が見つかりません。' using errcode='42501'; end if;
  return jsonb_build_object('token',token,'active',p_active);
end;
$$;
revoke all on function public.lab_student_open(text),public.lab_student_save(text,jsonb,uuid),public.lab_admin_create(text,jsonb),public.lab_admin_groups(),public.lab_admin_runs(uuid),public.lab_admin_access(uuid,boolean,boolean) from public,anon,authenticated;
grant execute on function public.lab_student_open(text),public.lab_student_save(text,jsonb,uuid) to anon;
grant execute on function public.lab_admin_create(text,jsonb),public.lab_admin_groups(),public.lab_admin_runs(uuid),public.lab_admin_access(uuid,boolean,boolean) to authenticated;
