-- ============================================================================
-- EASYWIN 1.0 - REWARDED ADS SYSTEM
-- CANONICAL SSOT - LOCKED - NON-NEGOTIABLE
-- Version: 2.2 · FINAL · Teaching-First
-- ============================================================================

-- PART 1: REWARDED ADS LOG TABLE
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.rewarded_ads_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    coins_awarded INTEGER NOT NULL DEFAULT 5 CHECK (coins_awarded = 5),
    watched_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ad_unit_id TEXT NOT NULL,
    environment TEXT NOT NULL CHECK (environment IN ('dev', 'staging', 'prod')),
    ad_provider_ref TEXT,
    
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_rewarded_ads_log_user ON public.rewarded_ads_log(user_id, watched_at DESC);
CREATE INDEX idx_rewarded_ads_log_watched_at ON public.rewarded_ads_log(watched_at DESC);
CREATE INDEX idx_rewarded_ads_log_environment ON public.rewarded_ads_log(environment, ad_unit_id);

-- PART 2: AD CONFIGURATION (LOCKED CONSTANTS)
-- ============================================================================

-- Constants (DO NOT MODIFY WITHOUT VERSION INCREMENT)
-- COINS_PER_AD = 5
-- MAX_ADS_PER_DAY = 8
-- MIN_TIME_BETWEEN_ADS = 5 minutes
-- TEST_AD_ID = 'ca-app-pub-3940256099942544/5224354917'
-- PROD_AD_ID = 'ca-app-pub-XXXXXXXXXXXXXXXX/XXXXXXXXXX' (to be configured)

-- PART 3: CHECK AD ELIGIBILITY FUNCTION
-- ============================================================================

-- Function: Check if user can watch rewarded ad
CREATE OR REPLACE FUNCTION public.check_ad_eligibility(
    p_user_id UUID,
    p_ad_unit_id TEXT,
    p_environment TEXT
)
RETURNS JSONB AS $$
DECLARE
    ads_watched_today INTEGER;
    last_ad_time TIMESTAMPTZ;
    time_since_last_ad INTERVAL;
    is_valid_ad_id BOOLEAN;
    test_ad_id TEXT := 'ca-app-pub-3940256099942544/5224354917';
    max_ads_per_day INTEGER := 8;
    min_cooldown_minutes INTEGER := 5;
BEGIN
    -- Validate Ad ID based on environment
    IF p_environment = 'prod' THEN
        -- In production, test Ad ID is forbidden
        IF p_ad_unit_id = test_ad_id THEN
            RETURN jsonb_build_object(
                'eligible', false,
                'reason', 'invalid_ad_id',
                'message', 'Test Ad ID not allowed in production'
            );
        END IF;
        -- Production Ad ID validation (configure your actual prod Ad ID)
        -- is_valid_ad_id := p_ad_unit_id = 'ca-app-pub-XXXXXXXXXXXXXXXX/XXXXXXXXXX';
        is_valid_ad_id := true; -- Placeholder until prod Ad ID is configured
    ELSE
        -- In non-production, only test Ad ID is allowed
        IF p_ad_unit_id != test_ad_id THEN
            RETURN jsonb_build_object(
                'eligible', false,
                'reason', 'invalid_ad_id',
                'message', 'Only test Ad ID allowed in non-production'
            );
        END IF;
        is_valid_ad_id := true;
    END IF;
    
    -- Check daily ad count
    SELECT COUNT(*) INTO ads_watched_today
    FROM public.rewarded_ads_log
    WHERE user_id = p_user_id
      AND watched_at >= CURRENT_DATE;
    
    IF ads_watched_today >= max_ads_per_day THEN
        RETURN jsonb_build_object(
            'eligible', false,
            'reason', 'daily_limit_reached',
            'message', 'You''ve reached today''s ad limit. Keep learning — you can earn more coins tomorrow.',
            'ads_watched_today', ads_watched_today,
            'max_ads_per_day', max_ads_per_day
        );
    END IF;
    
    -- Check cooldown
    SELECT watched_at INTO last_ad_time
    FROM public.rewarded_ads_log
    WHERE user_id = p_user_id
    ORDER BY watched_at DESC
    LIMIT 1;
    
    IF last_ad_time IS NOT NULL THEN
        time_since_last_ad := NOW() - last_ad_time;
        
        IF time_since_last_ad < (min_cooldown_minutes || ' minutes')::INTERVAL THEN
            RETURN jsonb_build_object(
                'eligible', false,
                'reason', 'cooldown_active',
                'message', 'You can watch another ad in 5 minutes.',
                'seconds_remaining', EXTRACT(EPOCH FROM ((min_cooldown_minutes || ' minutes')::INTERVAL - time_since_last_ad))::INTEGER
            );
        END IF;
    END IF;
    
    -- Eligible
    RETURN jsonb_build_object(
        'eligible', true,
        'coins_per_ad', 5,
        'ads_watched_today', ads_watched_today,
        'ads_remaining_today', max_ads_per_day - ads_watched_today
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PART 4: CREDIT AD REWARD FUNCTION
-- ============================================================================

-- Function: Credit coins for completed ad (with strict validation)
CREATE OR REPLACE FUNCTION public.credit_ad_reward(
    p_user_id UUID,
    p_ad_unit_id TEXT,
    p_environment TEXT,
    p_ad_provider_ref TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    eligibility JSONB;
    coins_to_award INTEGER := 5;
    new_balance INTEGER;
    duplicate_check INTEGER;
BEGIN
    -- Check eligibility first
    eligibility := public.check_ad_eligibility(p_user_id, p_ad_unit_id, p_environment);
    
    IF NOT (eligibility->>'eligible')::BOOLEAN THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', eligibility->>'reason',
            'message', eligibility->>'message'
        );
    END IF;
    
    -- Check for duplicate callback (idempotency)
    IF p_ad_provider_ref IS NOT NULL THEN
        SELECT COUNT(*) INTO duplicate_check
        FROM public.rewarded_ads_log
        WHERE user_id = p_user_id
          AND ad_provider_ref = p_ad_provider_ref;
        
        IF duplicate_check > 0 THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'duplicate_callback',
                'message', 'This ad reward has already been credited'
            );
        END IF;
    END IF;
    
    -- TRANSACTIONAL: Log ad + Credit coins
    BEGIN
        -- Log ad watch
        INSERT INTO public.rewarded_ads_log (
            user_id,
            coins_awarded,
            ad_unit_id,
            environment,
            ad_provider_ref
        ) VALUES (
            p_user_id,
            coins_to_award,
            p_ad_unit_id,
            p_environment,
            p_ad_provider_ref
        );
        
        -- Credit coins via coin_ledger
        INSERT INTO public.coin_ledger (
            user_id,
            amount,
            transaction_type,
            description,
            state
        ) VALUES (
            p_user_id,
            coins_to_award,
            'EARNED',
            'Rewarded ad completion',
            'COMMITTED'
        );
        
        -- Get new balance
        SELECT COALESCE(SUM(
            CASE 
                WHEN state = 'COMMITTED' THEN amount
                ELSE 0
            END
        ), 0) INTO new_balance
        FROM public.coin_ledger
        WHERE user_id = p_user_id;
        
        RETURN jsonb_build_object(
            'success', true,
            'coins_awarded', coins_to_award,
            'new_balance', new_balance,
            'message', 'Coins credited successfully'
        );
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'transaction_failed',
            'message', 'Failed to credit coins. Please try again.'
        );
    END;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PART 5: GET AD STATS FUNCTION
-- ============================================================================

-- Function: Get user's ad statistics
CREATE OR REPLACE FUNCTION public.get_ad_stats(p_user_id UUID)
RETURNS JSONB AS $$
DECLARE
    ads_watched_today INTEGER;
    total_ads_watched INTEGER;
    total_coins_earned INTEGER;
    last_ad_time TIMESTAMPTZ;
    max_ads_per_day INTEGER := 8;
BEGIN
    -- Ads watched today
    SELECT COUNT(*) INTO ads_watched_today
    FROM public.rewarded_ads_log
    WHERE user_id = p_user_id
      AND watched_at >= CURRENT_DATE;
    
    -- Total ads watched
    SELECT COUNT(*) INTO total_ads_watched
    FROM public.rewarded_ads_log
    WHERE user_id = p_user_id;
    
    -- Total coins earned from ads
    SELECT COALESCE(SUM(coins_awarded), 0) INTO total_coins_earned
    FROM public.rewarded_ads_log
    WHERE user_id = p_user_id;
    
    -- Last ad time
    SELECT watched_at INTO last_ad_time
    FROM public.rewarded_ads_log
    WHERE user_id = p_user_id
    ORDER BY watched_at DESC
    LIMIT 1;
    
    RETURN jsonb_build_object(
        'ads_watched_today', ads_watched_today,
        'ads_remaining_today', max_ads_per_day - ads_watched_today,
        'total_ads_watched', total_ads_watched,
        'total_coins_earned', total_coins_earned,
        'last_ad_time', last_ad_time,
        'coins_per_ad', 5,
        'max_ads_per_day', max_ads_per_day
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PART 6: RLS POLICIES
-- ============================================================================

ALTER TABLE public.rewarded_ads_log ENABLE ROW LEVEL SECURITY;

-- Policy: Users can view their own ad log
CREATE POLICY "Users view own ad log"
    ON public.rewarded_ads_log FOR SELECT
    USING (user_id = auth.uid());

-- Policy: Only backend can insert (via RPC)
-- No direct inserts from client

-- Admins can view all ad logs
CREATE POLICY "Admins view all ad logs"
    ON public.rewarded_ads_log FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = auth.uid()
              AND role IN ('ops_admin', 'super_admin')
        )
    );

COMMENT ON TABLE public.rewarded_ads_log IS 'Rewarded ad watch log. Coins-only rewards. Teaching-first limits.';
COMMENT ON FUNCTION public.check_ad_eligibility IS 'Check if user can watch ad (daily limit, cooldown, Ad ID validation).';
COMMENT ON FUNCTION public.credit_ad_reward IS 'Credit coins for completed ad. Environment-aware Ad ID validation. Transactional.';
COMMENT ON FUNCTION public.get_ad_stats IS 'Get user ad statistics (today, total, coins earned).';
