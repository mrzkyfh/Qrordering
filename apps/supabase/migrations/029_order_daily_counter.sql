-- Daily order number counter per outlet
-- Resets to 1 each day (Asia/Jakarta timezone)
-- Atomic increment to prevent duplicate numbers under concurrent orders

CREATE TABLE IF NOT EXISTS order_daily_counters (
  outlet_id    UUID NOT NULL REFERENCES outlets(id) ON DELETE CASCADE,
  counter_date DATE NOT NULL,
  last_number  INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (outlet_id, counter_date)
);

ALTER TABLE order_daily_counters ENABLE ROW LEVEL SECURITY;

-- Only authenticated outlet staff can read counters
CREATE POLICY "order_counters_select" ON order_daily_counters FOR SELECT USING (
  is_owner() OR outlet_id = auth_outlet_id()
);

-- Function callable by anon (customer QR) and authenticated (kasir)
-- Uses INSERT ... ON CONFLICT DO UPDATE RETURNING for atomic increment
CREATE OR REPLACE FUNCTION get_next_order_number(p_outlet_id UUID)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_number INTEGER;
  v_today  DATE;
BEGIN
  v_today := (NOW() AT TIME ZONE 'Asia/Jakarta')::DATE;

  INSERT INTO order_daily_counters (outlet_id, counter_date, last_number)
  VALUES (p_outlet_id, v_today, 1)
  ON CONFLICT (outlet_id, counter_date)
  DO UPDATE SET last_number = order_daily_counters.last_number + 1
  RETURNING last_number INTO v_number;

  RETURN LPAD(v_number::TEXT, 3, '0');
END;
$$;

-- Grant to both anon (customer menu) and authenticated (kasir/mobile)
GRANT EXECUTE ON FUNCTION get_next_order_number(UUID) TO anon;
GRANT EXECUTE ON FUNCTION get_next_order_number(UUID) TO authenticated;
