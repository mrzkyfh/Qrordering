# QA Workspace — QrOrdering

Folder ini adalah ruang kerja QA. Semua file testing dan bug report disimpan di sini.

## Struktur

```
qa/
├── sql/          → SQL test scripts (jalankan di Supabase SQL Editor)
├── ui/           → Playwright UI test scripts (node --input-type=module < file.mjs)
└── reports/      → Bug report per sesi (format: YYYY-MM-DD_BUG_REPORT.md)
```

## Cara Jalankan

### SQL Test
Buka Supabase SQL Editor → paste isi file → Run → lihat tab Results

### UI Test
```bash
cd apps/owner-panel
node --input-type=module < ../../qa/ui/ui_test_stock.mjs
```
Screenshot hasil tersimpan di `/tmp/*.png`

## Log Sesi

| Tanggal | Scope | File | Hasil |
|---|---|---|---|
| 2026-05-24 | inventory_recipes (migration 009) | [sql/test_inventory_recipes.sql](sql/test_inventory_recipes.sql) | 11/11 PASS (setelah fix 010) |
| 2026-05-24 | StockManager UI | [ui/ui_test_stock.mjs](ui/ui_test_stock.mjs) | 12 PASS, 0 FAIL, 2 WARN |
| 2026-05-24 | Bug Report | [reports/2026-05-24_BUG_REPORT.md](reports/2026-05-24_BUG_REPORT.md) | 4 bug (3 fixed, 1 open) |
| 2026-05-24 | RLS + Edge Cases SQL | [sql/test_rls_dan_edge_cases.sql](sql/test_rls_dan_edge_cases.sql) | Perlu dijalankan di Supabase SQL Editor |
| 2026-05-24 | UI Edge Cases | [ui/ui_test_edge_cases.mjs](ui/ui_test_edge_cases.mjs) | 6 PASS, 0 FAIL, 1 WARN |
| 2026-05-24 | Bug Report Sesi 2 | [reports/2026-05-24_BUG_REPORT_session2.md](reports/2026-05-24_BUG_REPORT_session2.md) | 2 bug (BUG-005 Critical, BUG-006 Low) |
| 2026-05-24 | MenuManager + Recipe | [ui/ui_test_menu_recipes.mjs](ui/ui_test_menu_recipes.mjs) | 6 PASS, 0 FAIL, 4 WARN |
| 2026-05-24 | Reports + Dashboard | [ui/ui_test_reports.mjs](ui/ui_test_reports.mjs) | 8 PASS, 0 FAIL, 2 WARN |
| 2026-05-24 | Bug Report Sesi 3 | [reports/2026-05-24_BUG_REPORT_session3.md](reports/2026-05-24_BUG_REPORT_session3.md) | 1 bug baru (BUG-007 Low) |
