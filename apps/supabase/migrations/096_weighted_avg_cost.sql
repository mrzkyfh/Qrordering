-- 096_weighted_avg_cost.sql
-- FITUR NEW-4 (Fase 1) — HPP akurat: biaya bahan baku diperbarui saat pembelian.
--
-- Masalah: HPP dihitung dari `ingredients.cost_per_unit`, tapi mencatat
-- pembelian ('purchase') hanya menambah `stock_qty` — cost_per_unit TIDAK pernah
-- diperbarui. Akibatnya beli bahan dengan harga baru tak mengubah HPP → laba
-- kotor/margin salah.
--
-- Solusi: saat transaksi 'purchase' membawa cost_per_unit, perbarui
-- `ingredients.cost_per_unit` dengan RATA-RATA TERTIMBANG (weighted average):
--   biaya_baru = (qty_lama × biaya_lama + qty_beli × biaya_beli)
--                ────────────────────────────────────────────────
--                            (qty_lama + qty_beli)
-- Bila stok lama <= 0 (habis/oversold), langsung pakai biaya beli.

CREATE OR REPLACE FUNCTION apply_stock_transaction()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.type = 'purchase'
     AND NEW.cost_per_unit IS NOT NULL AND NEW.cost_per_unit > 0 THEN
    -- Pembelian dengan harga → update stok + biaya rata-rata tertimbang.
    UPDATE ingredients
    SET cost_per_unit = CASE
          WHEN stock_qty <= 0 THEN NEW.cost_per_unit
          ELSE ROUND(
            (stock_qty * cost_per_unit + NEW.qty * NEW.cost_per_unit)
            / NULLIF(stock_qty + NEW.qty, 0), 2)
        END,
        stock_qty  = stock_qty + NEW.qty,
        updated_at = NOW()
    WHERE id = NEW.ingredient_id;

  ELSIF NEW.type IN ('purchase', 'return', 'adjustment') THEN
    -- Masuk tanpa harga (atau return/adjustment) → hanya tambah stok.
    UPDATE ingredients
    SET stock_qty  = stock_qty + NEW.qty,
        updated_at = NOW()
    WHERE id = NEW.ingredient_id;

  ELSIF NEW.type IN ('usage', 'waste') THEN
    -- Keluar → kurangi stok (boleh negatif = sinyal oversell; simetris restore).
    UPDATE ingredients
    SET stock_qty  = stock_qty - NEW.qty,
        updated_at = NOW()
    WHERE id = NEW.ingredient_id;
  END IF;

  RETURN NEW;
END;
$$;
