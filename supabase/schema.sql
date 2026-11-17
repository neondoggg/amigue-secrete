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
  creator_token_hash text,
  created_at timestamptz not null default now()
);
alter table public.secret_groups add column if not exists creator_token_hash text;
create table if not exists public.secret_participants (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.secret_groups(id) on delete cascade,
  name text not null,
  shirt_size text,
  token_hash text not null,
  receiver_id uuid references public.secret_participants(id),
  joined_at timestamptz not null default now(),
  unique (group_id, token_hash)
);
alter table public.secret_participants add column if not exists shirt_size text;
update public.secret_participants p
set name='Felipe V.'
where lower(trim(p.name))='felipe'
  and not exists(select 1 from public.secret_participants other where other.group_id=p.group_id and lower(trim(other.name))='felipe v.');
update public.secret_groups g
set creator_token_hash=p.token_hash
from public.secret_participants p
where g.code='99905361' and p.group_id=g.id and lower(p.name)=lower('Felipe V.') and g.creator_token_hash is null;
create unique index if not exists secret_participant_names on public.secret_participants(group_id, lower(name));
alter table public.secret_groups enable row level security;
alter table public.secret_participants enable row level security;
revoke all on public.secret_groups, public.secret_participants from anon, authenticated;

drop function if exists public.create_group(text,text,text,text,text);
create or replace function public.create_group(p_name text,p_date text,p_budget text,p_location text,p_rules text,p_owner_token_hash text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_code text; v_date date;
begin
  begin v_date := p_date::date; exception when others then raise exception 'Data inválida.'; end;
  loop
    v_code := upper(encode(extensions.gen_random_bytes(4),'hex'));
    exit when not exists(select 1 from public.secret_groups where code=v_code);
  end loop;
  insert into public.secret_groups(code,name,exchange_date,budget,location,rules,creator_token_hash)
  values(v_code,p_name,v_date,p_budget,p_location,p_rules,p_owner_token_hash);
  return jsonb_build_object('code',v_code);
end $$;

drop function if exists public.join_group(text,text,text);
create or replace function public.join_group(p_code text,p_name text,p_token_hash text,p_shirt_size text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_group public.secret_groups; v_id uuid;
begin
  select * into v_group from public.secret_groups where code=upper(p_code) for update;
  if not found then raise exception 'Grupo não encontrado.'; end if;
  if v_group.drawn_at is not null then raise exception 'O sorteio já foi realizado; novas entradas estão fechadas.'; end if;
  if exists(select 1 from public.secret_participants where group_id=v_group.id and lower(name)=lower(trim(p_name))) then raise exception 'Esse nome já está na sala.'; end if;
  if p_shirt_size is not null and p_shirt_size not in ('PP','P','M','G','GG','XG') then raise exception 'Tamanho de camisa inválido.'; end if;
  insert into public.secret_participants(group_id,name,shirt_size,token_hash) values(v_group.id,trim(p_name),p_shirt_size,p_token_hash) returning id into v_id;
  return jsonb_build_object('id',v_id,'name',trim(p_name));
end $$;

drop function if exists public.read_group(text);
drop function if exists public.read_group(text,text);
create or replace function public.read_group(p_code text,p_owner_token_hash text,p_participant_token_hash text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare g public.secret_groups; names jsonb;
begin
  select * into g from public.secret_groups where code=upper(p_code);
  if not found then raise exception 'Grupo não encontrado.'; end if;
  select coalesce(jsonb_agg(name || case when shirt_size is null or shirt_size='' then '' else ' - Camisa ' || shirt_size end order by joined_at),'[]'::jsonb) into names from public.secret_participants where group_id=g.id;
  return jsonb_build_object('code',g.code,'name',g.name,'date',g.exchange_date,'budget',g.budget,'location',g.location,'rules',g.rules,'participants',names,'drawn',g.drawn_at is not null,'isOwner',g.creator_token_hash is not null and g.creator_token_hash=p_owner_token_hash,'isMember',p_participant_token_hash is not null and exists(select 1 from public.secret_participants where group_id=g.id and token_hash=p_participant_token_hash));
end $$;

drop function if exists public.draw_group(text,text);
create or replace function public.draw_group(p_code text,p_owner_token_hash text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare g public.secret_groups; ids uuid[]; shuffled uuid[]; n int; i int; j int; tries int:=0; tmp uuid;
begin
  select * into g from public.secret_groups where code=upper(p_code) for update;
  if not found then raise exception 'Grupo não encontrado.'; end if;
  if g.creator_token_hash is null or g.creator_token_hash<>p_owner_token_hash then raise exception 'Apenas quem criou o grupo pode iniciar o sorteio.'; end if;
  if g.drawn_at is not null then return jsonb_build_object('drawn',true); end if;
  select array_agg(id order by id) into ids from public.secret_participants where group_id=g.id;
  n:=coalesce(array_length(ids,1),0);
  if n<2 then raise exception 'É preciso ter pelo menos duas pessoas para sortear.'; end if;
  loop
    tries:=tries+1; shuffled:=ids;
    for i in reverse n..2 loop
      j:=1+floor(random()*i)::int; tmp:=shuffled[i]; shuffled[i]:=shuffled[j]; shuffled[j]:=tmp;
    end loop;
    exit when not exists(
      select 1
      from generate_subscripts(ids, 1) as gs(subscript)
      where ids[gs.subscript] = shuffled[gs.subscript]
    );
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

revoke all on function public.create_group(text,text,text,text,text,text) from public, anon, authenticated;
revoke all on function public.join_group(text,text,text,text) from public, anon, authenticated;
revoke all on function public.read_group(text,text,text) from public, anon, authenticated;
revoke all on function public.draw_group(text,text) from public, anon, authenticated;
revoke all on function public.get_assignment(text,text) from public, anon, authenticated;
grant execute on function public.create_group(text,text,text,text,text,text) to service_role;
grant execute on function public.join_group(text,text,text,text) to service_role;
grant execute on function public.read_group(text,text,text) to service_role;
grant execute on function public.draw_group(text,text) to service_role;
grant execute on function public.get_assignment(text,text) to service_role;
