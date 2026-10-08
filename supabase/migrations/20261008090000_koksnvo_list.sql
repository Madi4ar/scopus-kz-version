-- Классификация журналов по спискам КОКСНВО МНВО РК (Комитет по обеспечению
-- качества в сфере науки и высшего образования, правопреемник ККСОН МОН РК).
-- Источник: официальный перечень изданий, рекомендуемых для публикации основных
-- результатов научной деятельности — приказ председателя Комитета от 12.07.2024
-- № 603 (файл редакции от 22.09.2025, 4 списка: Список 1 / 2 / 3 / ВСУЗов).
-- Все три журнала пилота — в Списке 2.
alter table journals add column if not exists koksnvo_list smallint check (koksnvo_list in (1, 2, 3));
alter table journals add column if not exists koksnvo_order text;

update journals set
  koksnvo_list = 2,
  koksnvo_order = 'Приказ КОКСНВО МНВО РК от 12.07.2024 № 603 (ред. от 22.09.2025)'
where name like 'Bulletin of L.N. Gumilyov%'
   or name like 'Bulletin of the Karaganda%'
   or name like 'Herald of Journalism%';
