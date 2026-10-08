// Проверка цитирований через OpenAlex (бесплатный API, без ключа) с сверкой
// цитирующих источников против официального списка Scopus (таблица scopus_sources,
// загружена из публичного Source Title List Elsevier).
//
// Для каждой статьи с DOI:
//   1. GET https://api.openalex.org/works/doi:{doi} -> cited_by_count, cited_by_api_url
//   2. GET {cited_by_api_url}&per-page=200 -> до 200 цитирующих работ (для нишевых
//      региональных журналов этого обычно достаточно)
//   3. ISSN/EISSN каждой цитирующей работы сверяется с scopus_sources
//   4. cited_by_scopus_count = число цитирующих работ, чей журнал найден в Scopus
//
// Это оценка снизу, а не официальные цифры Scopus (Scopus использует свой индекс
// цитирований, который не идентичен тому, что видно через OpenAlex/Crossref), но
// не требует платного/институционального доступа к Scopus API.

import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";

const BATCH_SIZE = 40;
const RECHECK_AFTER_DAYS = 30;

function normIssn(s: unknown): string {
  return String(s ?? "").replace(/-/g, "").toUpperCase();
}

function extractIssns(work: Record<string, unknown>): string[] {
  const loc = (work.primary_location ?? {}) as Record<string, unknown>;
  const source = (loc.source ?? {}) as Record<string, unknown>;
  const list: string[] = [];
  if (source.issn_l) list.push(String(source.issn_l));
  if (Array.isArray(source.issn)) list.push(...(source.issn as unknown[]).map(String));
  return [...new Set(list.map(normIssn).filter(Boolean))];
}

async function fetchOpenAlexWork(doi: string): Promise<Record<string, unknown> | null> {
  const res = await fetch(`https://api.openalex.org/works/doi:${encodeURIComponent(doi)}`, {
    headers: { "User-Agent": "scopus-kz-registry-citation-check/0.1" },
  });
  if (!res.ok) return null;
  return res.json();
}

// OpenAlex больше не отдаёт `cited_by_api_url` в ответе /works/doi:{doi} — строим
// запрос сами через filter=cites:{short work id}, например W4392177165.
async function fetchCitingWorks(openAlexWorkId: string): Promise<Record<string, unknown>[]> {
  const shortId = openAlexWorkId.split("/").pop();
  if (!shortId) return [];
  const res = await fetch(`https://api.openalex.org/works?filter=cites:${shortId}&per-page=200`, {
    headers: { "User-Agent": "scopus-kz-registry-citation-check/0.1" },
  });
  if (!res.ok) return [];
  const data = await res.json();
  return (data.results ?? []) as Record<string, unknown>[];
}

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function processArticle(article: { id: string; doi: string }) {
  const work = await fetchOpenAlexWork(article.doi);
  if (!work) {
    return { id: article.id, cited_by_count: 0, cited_by_scopus_count: 0, citing_works: [] as unknown[] };
  }

  const citedByCount = Number(work.cited_by_count ?? 0);
  let citingWorks: Record<string, unknown>[] = [];
  if (citedByCount > 0 && work.id) {
    citingWorks = await fetchCitingWorks(String(work.id));
  }

  const summaries = citingWorks.map((w) => {
    const issns = extractIssns(w);
    const loc = (w.primary_location ?? {}) as Record<string, unknown>;
    const source = (loc.source ?? {}) as Record<string, unknown>;
    return {
      title: w.display_name ?? null,
      journal: source.display_name ?? null,
      year: w.publication_year ?? null,
      doi: w.doi ?? null,
      issns,
    };
  });

  return { id: article.id, cited_by_count: citedByCount, citing_works: summaries };
}

export default {
  fetch: withSupabase({ auth: ["secret"] }, async (_req, ctx) => {
    if (ctx.authMode !== "secret") {
      return Response.json({ error: "This endpoint requires the service_role key." }, { status: 401 });
    }

    const supabase = ctx.supabaseAdmin;
    const cutoff = new Date(Date.now() - RECHECK_AFTER_DAYS * 86400 * 1000).toISOString();

    const { data: articles, error } = await supabase
      .from("articles")
      .select("id,doi")
      .not("doi", "is", null)
      .or(`citations_checked_at.is.null,citations_checked_at.lt.${cutoff}`)
      .order("citations_checked_at", { ascending: true, nullsFirst: true })
      .limit(BATCH_SIZE);

    if (error) return Response.json({ error: error.message }, { status: 500 });
    if (!articles || articles.length === 0) {
      return Response.json({ processed: 0, message: "Nothing to check." });
    }

    const results = [];
    for (const article of articles as { id: string; doi: string }[]) {
      try {
        results.push(await processArticle(article));
      } catch (e) {
        results.push({ id: article.id, cited_by_count: null, citing_works: [], error: String(e) });
      }
      await sleep(120); // вежливая пауза между запросами к OpenAlex
    }

    // Собираем все ISSN из всех citing_works этого батча и одним запросом
    // проверяем, какие из них есть в scopus_sources.
    const allIssns = new Set<string>();
    for (const r of results) {
      for (const w of (r.citing_works ?? []) as { issns: string[] }[]) {
        for (const issn of w.issns) allIssns.add(issn);
      }
    }

    let scopusIssns = new Set<string>();
    if (allIssns.size > 0) {
      const issnList = [...allIssns];
      const { data: matches } = await supabase
        .from("scopus_sources")
        .select("issn,eissn")
        .or(`issn.in.(${issnList.join(",")}),eissn.in.(${issnList.join(",")})`);
      for (const m of matches ?? []) {
        if (m.issn) scopusIssns.add(m.issn);
        if (m.eissn) scopusIssns.add(m.eissn);
      }
    }

    let withCitations = 0;
    for (const r of results) {
      const citingWorks = (r.citing_works ?? []) as { issns: string[] }[];
      const annotated = citingWorks.map((w) => ({ ...w, in_scopus: w.issns.some((i) => scopusIssns.has(i)) }));
      const scopusCount = annotated.filter((w) => w.in_scopus).length;
      if ((r.cited_by_count ?? 0) > 0) withCitations++;

      await supabase
        .from("articles")
        .update({
          cited_by_count: r.cited_by_count,
          cited_by_scopus_count: scopusCount,
          citing_works: annotated.slice(0, 20),
          citations_checked_at: new Date().toISOString(),
        })
        .eq("id", r.id);
    }

    return Response.json({ processed: results.length, withCitations });
  }),
};
