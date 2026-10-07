// Харвестер метаданных статей через OAI-PMH для журналов из реестра.
// Запускается по cron (pg_cron -> net.http_post с service_role ключом) или вручную.
//
// Для каждого активного журнала с заполненным oai_endpoint:
//   1. делает ListRecords (metadataPrefix=oai_dc), постранично через resumptionToken;
//   2. при повторном запуске использует last_crawled_at как `from`, чтобы тянуть только новое/обновлённое;
//   3. нормализует Dublin Core в строки таблицы `articles` и делает upsert по (journal_id, oai_identifier);
//   4. по завершении журнала обновляет journals.last_crawled_at.

import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";
import { XMLParser } from "npm:fast-xml-parser@4.5.0";

const MAX_PAGES_PER_JOURNAL = 100;

// Только "record" форсируем в массив (чтобы страница с 1 записью не ломала .map()).
// Остальные повторяемые dc:* поля (title, creator, subject, identifier, ...) нормализуются
// через toArray() ниже — forcing их здесь по имени тега задевает и header.identifier
// (единственный OAI-идентификатор записи), который не должен быть массивом.
const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: "@_",
  removeNSPrefix: true,
  isArray: (name: string, jPath: string) => name === "record" || jPath.endsWith(".ListRecords.record"),
});

function textOf(node: unknown): string {
  if (node == null) return "";
  if (typeof node === "string") return node.trim();
  if (typeof node === "object" && "#text" in (node as Record<string, unknown>)) {
    return String((node as Record<string, unknown>)["#text"]).trim();
  }
  return "";
}

function langOf(node: unknown): string {
  if (node == null || typeof node !== "object") return "";
  const o = node as Record<string, unknown>;
  return String(o["@_lang"] ?? o["@_xml:lang"] ?? "").toLowerCase();
}

function toArray<T>(v: T | T[] | undefined | null): T[] {
  if (v == null) return [];
  return Array.isArray(v) ? v : [v];
}

function pickPreferred(nodes: unknown[], order = ["ru", "en", "kk"]): string {
  if (nodes.length === 0) return "";
  for (const pref of order) {
    const hit = nodes.find((n) => langOf(n).startsWith(pref));
    if (hit) return textOf(hit);
  }
  return textOf(nodes[0]);
}

function classifyIdentifier(raw: string): { doi?: string; pdf?: string; article?: string } {
  const doiMatch = raw.match(/(?:doi\.org\/|^)(10\.\d{4,9}\/\S+)$/i);
  if (doiMatch) return { doi: doiMatch[1] };
  if (/\.pdf($|\?)/i.test(raw) || /\/download\//i.test(raw)) return { pdf: raw };
  if (/^https?:\/\//i.test(raw)) return { article: raw };
  return {};
}

function extractVolumeIssuePages(source: string): { volume: string | null; issue: string | null; pages: string | null } {
  const vol = source.match(/Vol\.?\s*(\d+)/i);
  const iss = source.match(/No\.?\s*(\d+)/i);
  const pages = source.match(/(\d+)\s*[-–]\s*(\d+)\s*$/);
  return {
    volume: vol ? vol[1] : null,
    issue: iss ? iss[1] : null,
    pages: pages ? `${pages[1]}-${pages[2]}` : null,
  };
}

function toMetadataQuality(row: Record<string, unknown>): "complete" | "partial" | "minimal" {
  const has = (k: string) => Boolean(row[k]);
  if (has("doi") && has("abstract") && has("authors") && has("keywords")) return "complete";
  if (has("authors") && (has("abstract") || has("doi"))) return "partial";
  return "minimal";
}

interface Journal {
  id: string;
  name: string;
  oai_endpoint: string | null;
  last_crawled_at: string | null;
}

function recordToArticleRow(journalId: string, record: Record<string, unknown>) {
  const header = (record.header ?? {}) as Record<string, unknown>;
  if (String(header["@_status"] ?? "") === "deleted") return null;

  const oaiIdentifier = textOf(header.identifier);
  const metadata = (record.metadata ?? {}) as Record<string, unknown>;
  const dc = (metadata.dc ?? {}) as Record<string, unknown>;

  const titles = toArray(dc.title);
  const creators = toArray(dc.creator);
  const subjects = toArray(dc.subject);
  const descriptions = toArray(dc.description);
  const dates = toArray(dc.date);
  const identifiers = toArray(dc.identifier).map(textOf).filter(Boolean);
  const sources = toArray(dc.source);
  const languages = toArray(dc.language);

  let doi: string | null = null;
  let pdfUrl: string | null = null;
  let articleUrl: string | null = null;
  for (const id of identifiers) {
    const c = classifyIdentifier(id);
    if (c.doi && !doi) doi = c.doi;
    if (c.pdf && !pdfUrl) pdfUrl = c.pdf;
    if (c.article && !articleUrl) articleUrl = c.article;
  }
  if (!articleUrl && identifiers.length > 0) articleUrl = identifiers[0];

  const sourceText = sources.length ? textOf(sources[0]) : "";
  const { volume, issue, pages } = extractVolumeIssuePages(sourceText);

  const setSpec = toArray(header.setSpec).map(textOf).join(", ");
  const section = setSpec.includes(":") ? setSpec.split(":").slice(1).join(":") : setSpec || null;

  const pubDateRaw = dates.length ? textOf(dates[0]) : "";
  const pubDate = /^\d{4}-\d{2}-\d{2}/.test(pubDateRaw) ? pubDateRaw.slice(0, 10) : null;

  const row: Record<string, unknown> = {
    journal_id: journalId,
    oai_identifier: oaiIdentifier,
    title: pickPreferred(titles) || "(без названия)",
    authors: creators.map(textOf).filter(Boolean).join("; ") || null,
    abstract: pickPreferred(descriptions) || null,
    keywords: subjects.map(textOf).filter(Boolean).join("; ") || null,
    doi,
    publication_date: pubDate,
    volume,
    issue,
    pages,
    language: languages.length ? textOf(languages[0]) : (langOf(titles[0]) || null),
    article_url: articleUrl,
    pdf_url: pdfUrl,
    section,
    raw_metadata: dc,
    updated_at: new Date().toISOString(),
  };
  row.metadata_quality = toMetadataQuality(row);
  return row;
}

async function fetchOaiPage(endpoint: string, params: Record<string, string>): Promise<Record<string, unknown>> {
  const url = new URL(endpoint);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  const res = await fetch(url.toString(), {
    headers: { "User-Agent": "scopus-kz-registry-harvester/0.1 (+MVP pilot)" },
  });
  if (!res.ok) throw new Error(`OAI request failed: ${res.status} ${res.statusText}`);
  const xml = await res.text();
  const parsed = parser.parse(xml);
  const root = parsed["OAI-PMH"];
  if (!root) throw new Error("Unexpected OAI-PMH response shape");
  if (root.error) {
    const err = root.error;
    const code = typeof err === "object" ? err["@_code"] : "unknown";
    const msg = typeof err === "object" ? err["#text"] : String(err);
    throw new Error(`OAI-PMH error [${code}]: ${msg}`);
  }
  return root;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function harvestJournal(supabase: any, journal: Journal) {
  if (!journal.oai_endpoint) return { journal: journal.name, skipped: "no oai_endpoint" };

  let upserted = 0;
  let pages = 0;
  let resumptionToken: string | null = null;
  const baseParams: Record<string, string> = { verb: "ListRecords", metadataPrefix: "oai_dc" };
  if (journal.last_crawled_at) {
    const from = new Date(journal.last_crawled_at);
    from.setDate(from.getDate() - 1); // буфер в 1 день на пересечение
    baseParams.from = from.toISOString().slice(0, 10);
  }

  while (pages < MAX_PAGES_PER_JOURNAL) {
    pages++;
    const params = resumptionToken
      ? { verb: "ListRecords", resumptionToken }
      : baseParams;

    const root = await fetchOaiPage(journal.oai_endpoint, params);
    const listRecords = root.ListRecords as Record<string, unknown> | undefined;
    if (!listRecords) break;

    const records = toArray(listRecords.record) as Record<string, unknown>[];
    const rows = records
      .map((r) => recordToArticleRow(journal.id, r))
      .filter((r): r is Record<string, unknown> => r !== null && Boolean(r.oai_identifier));

    if (rows.length > 0) {
      const { error } = await supabase
        .from("articles")
        .upsert(rows, { onConflict: "journal_id,oai_identifier" });
      if (error) throw new Error(`Upsert failed for ${journal.name}: ${error.message}`);
      upserted += rows.length;
    }

    const rt = listRecords.resumptionToken;
    const rtText = rt && typeof rt === "object" ? textOf(rt) : (typeof rt === "string" ? rt : "");
    if (!rtText) break;
    resumptionToken = rtText;
  }

  await supabase
    .from("journals")
    .update({ last_crawled_at: new Date().toISOString() })
    .eq("id", journal.id);

  return { journal: journal.name, pages, upserted };
}

export default {
  fetch: withSupabase({ auth: ["secret"] }, async (_req, ctx) => {
    if (ctx.authMode !== "secret") {
      return Response.json({ error: "This endpoint requires the service_role key." }, { status: 401 });
    }

    const supabase = ctx.supabaseAdmin;
    const { data: journals, error } = await supabase
      .from("journals")
      .select("id,name,oai_endpoint,last_crawled_at")
      .eq("is_active", true)
      .not("oai_endpoint", "is", null);

    if (error) return Response.json({ error: error.message }, { status: 500 });

    const results = [];
    for (const journal of (journals ?? []) as Journal[]) {
      try {
        results.push(await harvestJournal(supabase, journal));
      } catch (e) {
        results.push({ journal: journal.name, error: String(e instanceof Error ? e.message : e) });
      }
    }

    return Response.json({ ranAt: new Date().toISOString(), results });
  }),
};
