begin;
alter table public.lab_classes add column if not exists share_token text;
update public.lab_classes set share_token=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','') where share_token is null;
alter table public.lab_groups add column if not exists sort_order integer;



create or replace function public.lab_admin_class_create(p_label text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); t text; cid uuid;
begin
  if p_label is null or length(btrim(p_label)) not between 1 and 100 then raise exception 'クラス名は1～100文字で入力してください。'; end if;
  t:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');
  insert into public.lab_classes(teacher_id,label,token_hash,share_token) values(uid,btrim(p_label),sha256(convert_to(t,'UTF8')),t) returning id into cid;
  return jsonb_build_object('id',cid,'label',btrim(p_label),'token',t);
end;
$$;

create or replace function public.lab_admin_class_link(p_class_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); t text; name text;
begin
  t:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');
  update public.lab_classes set token_hash=sha256(convert_to(t,'UTF8')),share_token=t where id=p_class_id and teacher_id=uid returning label into name;
  if not found then raise exception 'クラスが見つかりません。' using errcode='42501'; end if;
  return jsonb_build_object('label',name,'token',t);
end;
$$;

create or replace function public.lab_admin_classes() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); result jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'label',c.label,'link_token',c.share_token,'groups',(select count(*) from public.lab_groups where class_id=c.id),
    'settings',coalesce(c.settings,(select g.settings from public.lab_groups g where g.class_id=c.id order by g.created_at,g.id limit 1),
      '{"temp":25,"pressure":101300,"volume":2,"unit":"min","input":"total","mode":"estimate","c0":"","wet":true}'::jsonb)) order by c.created_at desc),'[]') into result
    from public.lab_classes c where teacher_id=uid;
  return result;
end;
$$;

create or replace function public.lab_course_open(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c public.lab_classes; options jsonb;
begin
  select * into c from public.lab_classes where token_hash=sha256(convert_to(p_token,'UTF8')) or share_token=p_token;
  if not found then raise exception '講座リンクが無効です。'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'label',g.label) order by coalesce(g.sort_order,2147483647),g.created_at desc,g.id desc),'[]') into options
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
    where (c.token_hash=sha256(convert_to(p_token,'UTF8')) or c.share_token=p_token) and g1.id=p_group_id and g1.active for update of g1;
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

create or replace function public.lab_admin_groups() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); result jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'label',g.label,'sort_order',g.sort_order,'class_id',g.class_id,'class_label',c.label,'active',g.active,'settings',g.settings,
    'created_at',g.created_at,'runs',(select count(*) from public.lab_runs where group_id=g.id),
    'latest',(select jsonb_build_object('id',r.id,'team_label',r.team_label,'temperature',(coalesce(r.settings,g.settings)->>'temp')::double precision,
      'concentrations',r.analysis->'concentrations','k',r.analysis->'k','created_at',r.created_at) from public.lab_runs r where r.group_id=g.id order by r.created_at desc,r.id desc limit 1),
    'teams',(select coalesce(jsonb_agg(jsonb_build_object('team_label',t.team_label,'temperature',(coalesce(t.settings,g.settings)->>'temp')::double precision,
      'concentrations',t.analysis->'concentrations','k',t.analysis->'k','created_at',t.created_at)),'[]') from
      (select distinct on (team_label) * from public.lab_runs where group_id=g.id order by team_label,created_at desc,id desc) t)) order by g.class_id nulls last,coalesce(g.sort_order,2147483647),g.created_at desc,g.id desc),'[]') into result
    from public.lab_groups g left join public.lab_classes c on c.id=g.class_id where g.teacher_id=uid;
  return result;
end;
$$;

create or replace function public.lab_admin_course_order(p_class_id uuid,p_group_ids uuid[]) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=public.lab_require_teacher(); expected integer; updated integer;
begin
  perform 1 from public.lab_classes where id=p_class_id and teacher_id=uid for update;
  if not found then raise exception '講座が見つかりません。' using errcode='42501';end if;
  select count(*) into expected from public.lab_groups where class_id=p_class_id;
  if p_group_ids is null or array_position(p_group_ids,null) is not null or cardinality(p_group_ids)<>expected
    or (select count(distinct x) from unnest(p_group_ids) x)<>expected
    or (select count(*) from public.lab_groups where class_id=p_class_id and teacher_id=uid and id=any(p_group_ids))<>expected then
    raise exception 'クラス一覧が変更されています。一覧を更新して並べ替えてください。';
  end if;
  update public.lab_groups g set sort_order=o.position::integer-1 from unnest(p_group_ids) with ordinality o(id,position)
    where g.id=o.id and g.class_id=p_class_id and g.teacher_id=uid;
  get diagnostics updated=row_count;
  if updated<>expected then raise exception 'クラス一覧が変更されています。一覧を更新してください。';end if;
  return jsonb_build_object('saved',true);
end;
$$;
revoke all on function public.lab_admin_course_order(uuid,uuid[]) from public,anon,authenticated;
grant execute on function public.lab_admin_course_order(uuid,uuid[]) to authenticated;
notify pgrst,'reload schema';
commit;
