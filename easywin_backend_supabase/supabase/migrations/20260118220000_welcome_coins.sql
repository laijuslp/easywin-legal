-- =============================================================================
-- EASYWIN 1.0 — WELCOME COINS IMPLEMENTATION
-- =============================================================================

-- 1️⃣ SCHEMA CHANGE
ALTER TABLE public.profiles
ADD COLUMN welcome_coins_granted boolean NOT NULL DEFAULT false;

-- 2️⃣ INTERNAL FUNCTION (Security Definer)
-- This function contains the core logic for granting welcome coins.
-- It can be called by triggers or other functions.
CREATE OR REPLACE FUNCTION public.internal_grant_welcome_coins(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_amount integer := 50;
BEGIN
  -- 1. Check if already granted (Safety Guarantee)
  IF EXISTS (
    SELECT 1 FROM public.profiles 
    WHERE id = p_user_id AND welcome_coins_granted = true
  ) THEN
    RETURN;
  END IF;

  -- 2. Ensure wallet exists
  INSERT INTO public.user_wallet (user_id, balance)
  VALUES (p_user_id, 0)
  ON CONFLICT (user_id) DO NOTHING;

  -- 3. Grant Coins (Update Wallet)
  UPDATE public.user_wallet
  SET balance = balance + v_amount,
      updated_at = now()
  WHERE user_id = p_user_id;

  -- 4. Record in Ledger (Audit Trail)
  INSERT INTO public.coin_transactions (
    user_id,
    amount,
    reason,
    created_at
  ) VALUES (
    p_user_id,
    v_amount,
    'welcome_bonus',
    now()
  );

  -- 5. Lock grant forever (Double grant prevention)
  UPDATE public.profiles
  SET welcome_coins_granted = true
  WHERE id = p_user_id;
END;
$$;

-- 3️⃣ REQUIRED RPC — grant_welcome_coins
-- This is the wrapper provided in the SSOT, using auth.uid().
CREATE OR REPLACE FUNCTION public.grant_welcome_coins()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  v_user_id := auth.uid();

  IF v_user_id IS NULL THEN
    RETURN;
  END IF;

  PERFORM public.internal_grant_welcome_coins(v_user_id);
END;
$$;

-- 4️⃣ AUTH FLOW INTEGRATION (Update handle_new_user)
-- We modify the trigger to use the new Welcome Coins system.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  -- Create Profile
  INSERT INTO public.profiles (id, email, display_name, avatar_url)
  VALUES (
    NEW.id,
    NEW.email,
    NEW.raw_user_meta_data->>'display_name',
    NEW.raw_user_meta_data->>'avatar_url'
  );

  -- Grant Welcome Coins immediately (Server-side Enforcement)
  -- This ensures coins are granted exactly once on sign-up.
  PERFORM public.internal_grant_welcome_coins(NEW.id);

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5️⃣ FINAL SSOT STATEMENT
COMMENT ON FUNCTION public.grant_welcome_coins IS 'EasyWin 1.0 grants exactly 50 welcome coins once, immediately after first sign-up. This grant is enforced server-side and permanently recorded.';
