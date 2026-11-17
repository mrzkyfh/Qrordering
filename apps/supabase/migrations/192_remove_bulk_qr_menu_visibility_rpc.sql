-- Visibility is saved together with each product from the add/edit product form.
-- The former bulk settings RPC is no longer exposed or needed.
DROP FUNCTION IF EXISTS public.set_qr_menu_visibility(UUID, UUID[]);
