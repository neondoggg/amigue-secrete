-- Execute once in the Supabase SQL Editor. Private draw data is never exposed by a public table policy.
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.secret_groups (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  exchange_date date not null,
  budget text not null,
  location text not null,
  rules text not null,
  drawn_at timestamptz,
  created_at timestamptz not null default now()
);
create table if not exists public.secret_participants (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.secret_groups(id) on delete cascade,
  name text not null,
  token_hash text not null,
  receiver_id uuid references public.secret_participants(id),
  joined_at timestamptz not null default now(),
  unique (group_id, token_hash)
);
create unique index if not exists secret_participant_names on public.secret_participants(group_id, lower(name));
alter table public.secret_groups enable row level security;
alter table public.secret_participants enable row level security;
revoke all on public.secret_groups, public.secret_participants from anon, authenticated;

create or replace function public.create_group(p_name text,p_date text,p_budget text,p_location text,p_rules text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_code text; v_date date;
begin
  begin v_date := p_date::date; exception when others then raise exception 'Data inválida.'; end;
  loop
    v_code := upper(encode(extensions.gen_random_bytes(4),'hex'));
    exit when not exists(select 1 from public.secret_groups where code=v_code);
  end loop;
  insert into public.secret_groups(code,name,exchange_date,budget,location,rules)
  values(v_code,p_name,v_date,p_budget,p_location,p_rules);
  return jsonb_build_object('code',v_code);
end $$;

create or replace function public.join_group(p_code text,p_name text,p_token_hash text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_group public.secret_groups; v_id uuid;
begin
  select * into v_group from public.secret_groups where code=upper(p_code) for update;
  if not found then raise exception 'Grupo não encontrado.'; end if;
  if v_group.drawn_at is not null then raise exception 'O sorteio já foi realizado; novas entradas estão fechadas.'; end if;
  if exists(select 1 from public.secret_participants where group_id=v_group.id and lower(name)=lower(trim(p_name))) then raise exception 'Esse nome já está na sala.'; end if;
  insert into public.secret_participants(group_id,name,token_hash) values(v_group.id,trim(p_name),p_token_hash) returning id into v_id;
  return jsonb_build_object('id',v_id,'name',trim(p_name));
end $$;

create or replace function public.read_group(p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare g public.secret_groups; names jsonb;
begin
  select * into g from public.secret_groups where code=upper(p_code);
  if not found then raise exception 'Grupo não encontrado.'; end if;
  select coalesce(jsonb_agg(name order by joined_at),'[]'::jsonb) into names from public.secret_participants where group_id=g.id;
  return jsonb_build_object('code',g.code,'name',g.name,'date',g.exchange_date,'budget',g.budget,'location',g.location,'rules',g.rules,'participants',names,'drawn',g.drawn_at is not null);
end $$;

create or replace function public.draw_group(p_code text,p_token_hash text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare g public.secret_groups; ids uuid[]; shuffled uuid[]; n int; i int; j int; tries int:=0; tmp uuid;
begin
  select * into g from public.secret_groups where code=upper(p_code) for update;
  if not found then raise exception 'Grupo não encontrado.'; end if;
  if not exists(select 1 from public.secret_participants where group_id=g.id and token_hash=p_token_hash) then raise exception 'Entre na sala antes de sortear.'; end if;
  if g.drawn_at is not null then return jsonb_build_object('drawn',true); end if;
  select array_agg(id order by id) into ids from public.secret_participants where group_id=g.id;
  n:=coalesce(array_length(ids,1),0);
  if n<2 then raise exception 'É preciso ter pelo menos duas pessoas para sortear.'; end if;
  loop
    tries:=tries+1; shuffled:=ids;
    for i in reverse n..2 loop
      j:=1+floor(random()*i)::int; tmp:=shuffled[i]; shuffled[i]:=shuffled[j]; shuffled[j]:=tmp;
    end loop;
    exit when not exists(select 1 from generate_subscripts(ids,1) as x(i) where ids[i]=shuffled[i]);
    if tries>1000 then raise exception 'Não foi possível concluir o sorteio.'; end if;
  end loop;
  for i in 1..n loop update public.secret_participants set receiver_id=shuffled[i] where id=ids[i]; end loop;
  update public.secret_groups set drawn_at=now() where id=g.id;
  return jsonb_build_object('drawn',true);
end $$;

create or replace function public.get_assignment(p_code text,p_token_hash text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare g public.secret_groups; p public.secret_participants; receiver text;
begin
  select * into g from public.secret_groups where code=upper(p_code);
  if not found then raise exception 'Grupo não encontrado.'; end if;
  select * into p from public.secret_participants where group_id=g.id and token_hash=p_token_hash;
  if not found then raise exception 'Entre na sala para ver seu resultado.'; end if;
  if g.drawn_at is null then return jsonb_build_object('drawn',false); end if;
  select name into receiver from public.secret_participants where id=p.receiver_id;
  return jsonb_build_object('drawn',true,'receiver',receiver);
end $$;

revoke all on function public.create_group(text,text,text,text,text) from public, anon, authenticated;
revoke all on function public.join_group(text,text,text) from public, anon, authenticated;
revoke all on function public.read_group(text) from public, anon, authenticated;
revoke all on function public.draw_group(text,text) from public, anon, authenticated;
revoke all on function public.get_assignment(text,text) from public, anon, authenticated;
grant execute on function public.create_group(text,text,text,text,text) to service_role;
grant execute on function public.join_group(text,text,text) to service_role;
grant execute on function public.read_group(text) to service_role;
grant execute on function public.draw_group(text,text) to service_role;
grant execute on function public.get_assignment(text,text) to service_role;
