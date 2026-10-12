-- Профили авторов.
-- В articles.authors авторы лежат строкой "Фамилия, Инициалы; ..." — без ID и ORCID,
-- в разных форматах ("N. B. Rahmet", "Иванов И.И.") и часто продублированы
-- латиницей и кириллицей в одной статье ("Shirtaev, B.K.; ...; Ширтаев, Б.К.").
-- Поэтому автор = ключ "скелет фамилии + первый инициал", где скелет — транслит в
-- латиницу с выравниванием вариантов (kh/х, zh/ж, y/ы/i, ye/е, удвоенные буквы).
-- Однофамильцы с одинаковым инициалом склеиваются — осознанный компромисс MVP.

-- ---------- нормализация ----------

create or replace function author_skeleton(s text)
returns text
language sql
immutable
as $$
  select regexp_replace(
    regexp_replace(
      regexp_replace(
        replace(replace(replace(replace(replace(replace(
          translate(
            replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(
              lower(coalesce(s, '')),
              'ж', 'zh'), 'х', 'kh'), 'һ', 'h'), 'ц', 'ts'), 'ч', 'ch'), 'ш', 'sh'), 'щ', 'sh'),
              'ю', 'yu'), 'я', 'ya'), 'ё', 'e'), 'ә', 'a'),
            'абвгғдезийкқлмнңоөпрстуұүфыіэäöüışğñ',
            'abvggdeziikklmnnooprstuuufyieaouisgn'),
          'kh', 'h'), 'zh', 'j'), 'w', 'v'), 'q', 'k'), 'x', 'ks'), 'y', 'i'),
        '[^a-z]', '', 'g'),
      '(.)\1+', '\1', 'g'),
    'ie', 'e', 'g');
$$;

create or replace function author_key(raw_name text)
returns text
language plpgsql
immutable
as $$
declare
  n text := btrim(regexp_replace(regexp_replace(coalesce(raw_name, ''), '\s+', ' ', 'g'), ' ,', ',', 'g'));
  tokens text[];
  cnt int;
  surname text;
  given text := '';
  sk text;
begin
  if n = '' then
    return null;
  end if;
  if position(',' in n) > 0 then
    -- "Фамилия, Имя/Инициалы"
    surname := split_part(n, ',', 1);
    given := substr(n, position(',' in n) + 1);
  else
    tokens := string_to_array(n, ' ');
    cnt := array_length(tokens, 1);
    if cnt = 1 then
      surname := n;
    elsif tokens[1] ~ '\.$' or char_length(tokens[1]) <= 2 then
      -- "N. B. Rahmet" — инициалы впереди
      surname := tokens[cnt];
      given := array_to_string(tokens[1:cnt - 1], ' ');
    else
      -- "Иванов И.И." / "Ivanov Ivan"
      surname := tokens[1];
      given := array_to_string(tokens[2:cnt], ' ');
    end if;
  end if;
  sk := author_skeleton(surname);
  if char_length(sk) < 2 or sk in ('admin', 'anonim', 'anonimous', 'anonymous', 'author', 'editor') then
    return null;
  end if;
  return rtrim(sk || ' ' || left(author_skeleton(given), 1));
end;
$$;

-- Разбор строки authors: по одному ряду на автора, дубли (латиница/кириллица) схлопнуты.
create or replace function split_authors(authors text)
returns table (pos smallint, name text, author_key text)
language sql
immutable
as $$
  select distinct on (k) ord::smallint, nm, k
  from (
    select ord, btrim(regexp_replace(regexp_replace(x, '\s+', ' ', 'g'), ' ,', ',', 'g')) as nm, author_key(x) as k
    from unnest(string_to_array(authors, ';')) with ordinality as t(x, ord)
  ) s
  where k is not null
  order by k, ord;
$$;

-- ---------- таблица связей статья — автор ----------

create table if not exists article_authors (
  article_id uuid not null references articles(id) on delete cascade,
  position smallint not null,
  name text not null,
  author_key text not null,
  primary key (article_id, position)
);

create index if not exists article_authors_key_idx on article_authors (author_key text_pattern_ops, article_id);

alter table article_authors enable row level security;
drop policy if exists "article_authors public read" on article_authors;
create policy "article_authors public read" on article_authors for select using (true);

create or replace function sync_article_authors()
returns trigger
language plpgsql
as $$
begin
  delete from article_authors where article_id = new.id;
  insert into article_authors (article_id, position, name, author_key)
  select new.id, s.pos, s.name, s.author_key from split_authors(new.authors) s;
  return new;
end;
$$;

drop trigger if exists articles_sync_authors on articles;
create trigger articles_sync_authors
  after insert or update of authors on articles
  for each row execute function sync_article_authors();

-- бэкфилл существующих статей
truncate article_authors;
insert into article_authors (article_id, position, name, author_key)
select a.id, s.pos, s.name, s.author_key
from articles a
cross join lateral split_authors(a.authors) s
where a.authors is not null;

-- ---------- профиль автора ----------

create or replace function author_profile(p_name text)
returns jsonb
language sql
stable
as $$
  with k as (
    select author_key(p_name) as key
  ),
  mine as (
    select aa.article_id, aa.name
    from article_authors aa, k
    where aa.author_key = k.key
  ),
  arts as (
    select
      a.id,
      a.title,
      a.authors,
      a.publication_date,
      a.doi,
      a.article_url,
      a.journal_id,
      j.name as journal_name,
      coalesce(a.cited_by_count, 0) as cited_by_count,
      coalesce(a.cited_by_scopus_count, 0) as cited_by_scopus_count,
      coalesce((
        select array_agg((w ->> 'year')::int)
        from jsonb_array_elements(
          case when jsonb_typeof(a.citing_works) = 'array' then a.citing_works else '[]'::jsonb end
        ) w
        where (w ->> 'year') ~ '^\d{4}$'
      ), '{}') as citing_years
    from articles a
    join journals j on j.id = a.journal_id
    where a.id in (select article_id from mine)
  )
  select jsonb_build_object(
    'key', (select key from k),
    'name', (select mode() within group (order by name) from mine),
    'variants', (
      select coalesce(jsonb_agg(v order by c desc, v), '[]'::jsonb)
      from (select name as v, count(*) as c from mine group by name) s
    ),
    'articles', (
      select coalesce(jsonb_agg(to_jsonb(arts) order by publication_date desc nulls last), '[]'::jsonb)
      from arts
    ),
    'journals', (
      select coalesce(jsonb_agg(jsonb_build_object('id', journal_id, 'name', journal_name, 'count', c) order by c desc), '[]'::jsonb)
      from (select journal_id, journal_name, count(*) as c from arts group by journal_id, journal_name) s
    ),
    'coauthors', (
      select coalesce(jsonb_agg(jsonb_build_object('name', name, 'count', c) order by c desc, name), '[]'::jsonb)
      from (
        select mode() within group (order by aa.name) as name, count(distinct aa.article_id) as c
        from article_authors aa, k
        where aa.article_id in (select article_id from mine)
          and aa.author_key <> k.key
        group by aa.author_key
        order by c desc
        limit 30
      ) s
    )
  );
$$;

-- «Профили авторов» над выдачей: точное совпадение ключа или фамилия без инициала.
create or replace function search_authors(q text, limit_count int default 4)
returns table (name text, article_count bigint, citations bigint)
language sql
stable
as $$
  with k as (
    select author_key(q) as key
  )
  select
    mode() within group (order by aa.name) as name,
    count(*) as article_count,
    coalesce(sum(a.cited_by_count), 0) as citations
  from article_authors aa
  join articles a on a.id = aa.article_id
  cross join k
  where k.key is not null
    and (aa.author_key = k.key or aa.author_key like k.key || ' _')
  group by aa.author_key
  having count(*) >= 2
  order by count(*) desc
  limit limit_count;
$$;

grant select on article_authors to anon, authenticated;
grant execute on function author_profile(text) to anon, authenticated;
grant execute on function search_authors(text, int) to anon, authenticated;
