-- search_authors падал по statement_timeout: внутри SQL-функции ключ author_key(q)
-- — параметр, планировщик не может использовать индекс для LIKE 'ключ _' и сканирует
-- всю article_authors. С ключом-константой тот же запрос идёт по индексу за ~10 мс,
-- поэтому подставляем его через EXECUTE format(%L).

create or replace function search_authors(q text, limit_count int default 4)
returns table (name text, article_count bigint, citations bigint)
language plpgsql
stable
as $$
declare
  k text := author_key(q);
begin
  if k is null then
    return;
  end if;
  return query execute format($sql$
    select
      mode() within group (order by aa.name) as name,
      count(*) as article_count,
      coalesce(sum(a.cited_by_count), 0)::bigint as citations
    from article_authors aa
    join articles a on a.id = aa.article_id
    where aa.author_key = %1$L or aa.author_key like %2$L
    group by aa.author_key
    having count(*) >= 2
    order by count(*) desc
    limit %3$s
  $sql$, k, k || ' _', greatest(1, least(coalesce(limit_count, 4), 20)));
end;
$$;

grant execute on function search_authors(text, int) to anon, authenticated;
