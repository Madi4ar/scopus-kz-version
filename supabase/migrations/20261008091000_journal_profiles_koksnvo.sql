drop function if exists journal_profiles();

create function journal_profiles()
returns table (
  id uuid,
  name text,
  publisher text,
  base_url text,
  platform text,
  oai_endpoint text,
  issn_print text,
  issn_online text,
  language text,
  open_access boolean,
  discipline text,
  source_type text,
  koksnvo_list smallint,
  koksnvo_order text,
  last_crawled_at timestamptz,
  article_count bigint
)
language sql stable
as $$
  select
    j.id, j.name, j.publisher, j.base_url, j.platform, j.oai_endpoint,
    j.issn_print, j.issn_online, j.language, j.open_access, j.discipline,
    j.source_type, j.koksnvo_list, j.koksnvo_order, j.last_crawled_at,
    count(a.id) as article_count
  from journals j
  left join articles a on a.journal_id = j.id
  group by j.id
  order by j.name;
$$;
