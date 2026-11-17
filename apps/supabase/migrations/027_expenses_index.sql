-- Add missing index on expenses table for outlet_id + expense_date
-- Previously missing, causing full table scan on every Pengeluaran page load

CREATE INDEX IF NOT EXISTS idx_expenses_outlet_date
  ON expenses(outlet_id, expense_date DESC);
